import XCTest
@testable import Prizm

/// Prelogin uses the Identity service route of current servers, with a legacy fallback for older
/// ones (openspec change fix-prelogin-identity-endpoint, design D1–D3).
final class PreLoginEndpointTests: XCTestCase {

    private let base = URL(string: "https://vault.example.com")!
    private let email = "alice@example.com"
    private var sut: PrizmAPIClientImpl!

    /// Vaultwarden 1.37.4, PBKDF2 account (`src/api/core/accounts.rs:1412-1424`).
    private let vaultwarden1374Body = Data("""
        {"kdf":0,"kdfIterations":600000,"kdfMemory":null,"kdfParallelism":null,
         "kdfSettings":{"iterations":600000,"kdfType":0,"memory":null,"parallelism":null},"salt":null}
        """.utf8)

    /// Vaultwarden 1.35.4, Argon2id account (`src/api/core/accounts.rs:1238-1243`): flat fields only.
    private let vaultwarden1354Body = Data("""
        {"kdf":1,"kdfIterations":3,"kdfMemory":64,"kdfParallelism":4}
        """.utf8)

    /// Bitwarden server HEAD (`Identity/Models/Response/Accounts/PasswordPreloginResponseModel.cs`):
    /// the flat fields are nullable and marked for removal (PM-28143); `salt` is the email.
    private let bitwardenBody = Data("""
        {"kdf":0,"kdfIterations":600000,"kdfMemory":null,"kdfParallelism":null,
         "kdfSettings":{"kdfType":0,"iterations":600000,"memory":null,"parallelism":null},
         "salt":"alice@example.com"}
        """.utf8)

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        sut = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await sut.setBaseURL(base)
    }

    private var primaryPath: String { "/identity/accounts/prelogin/password" }
    private var legacyPath: String { "/identity/accounts/prelogin" }

    private func answer(primary: StubURLProtocol.Response, legacy: StubURLProtocol.Response = .status(500)) {
        let primaryPath = primaryPath
        StubURLProtocol.responder = { request in
            request.url?.path == primaryPath ? primary : legacy
        }
    }

    // MARK: - 1.1 / 1.2 Primary route

    func testPreLogin_postsEmailToIdentityPasswordRoute() async throws {
        answer(primary: .status(200, body: vaultwarden1374Body))

        _ = try await sut.preLogin(email: email)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 1, "The legacy route must not be used when the primary one works")
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://vault.example.com/identity/accounts/prelogin/password")
        XCTAssertEqual(requests.first?.headers["Content-Type"], "application/json")
        XCTAssertEqual(requests.first?.jsonBody as? [String: String], ["email": email])
        XCTAssertFalse(requests.contains { $0.url?.path == "/api/accounts/prelogin" })
    }

    // MARK: - 1.3 Legacy fallback on 404 and 405

    func testPreLogin_fallsBackToLegacyRoute_on404() async throws {
        try await assertFallsBack(onStatus: 404)
    }

    func testPreLogin_fallsBackToLegacyRoute_on405() async throws {
        try await assertFallsBack(onStatus: 405)
    }

    private func assertFallsBack(onStatus status: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        answer(primary: .status(status), legacy: .status(200, body: vaultwarden1354Body))

        let response = try await sut.preLogin(email: email)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [primaryPath, legacyPath], file: file, line: line)
        XCTAssertEqual(requests.last?.method, "POST", file: file, line: line)
        XCTAssertEqual(requests.last?.jsonBody as? [String: String], ["email": email], file: file, line: line)
        XCTAssertEqual(response.kdfParams, KdfParams(type: .argon2id, iterations: 3, memory: 64, parallelism: 4),
                       "The legacy route's response is returned", file: file, line: line)
    }

    func testPreLogin_legacyRouteFailure_isSurfaced() async throws {
        answer(primary: .status(404), legacy: .status(500))
        do {
            _ = try await sut.preLogin(email: email)
            XCTFail("Expected the legacy route's failure")
        } catch {
            guard case APIError.httpError(statusCode: 500, body: _) = error else {
                return XCTFail("The legacy route's error should be shown, got \(error)")
            }
        }
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, [primaryPath, legacyPath])
    }

    // MARK: - 1.4 Other failures are surfaced, without a second request

    func testPreLogin_400_isSurfacedWithoutFallback() async throws {
        try await assertSurfacedWithoutFallback(.status(400, body: Data(#"{"message":"bad"}"#.utf8))) { error in
            guard case APIError.httpError(statusCode: 400, body: _) = error else { return false }
            return true
        }
    }

    func testPreLogin_500_isSurfacedWithoutFallback() async throws {
        try await assertSurfacedWithoutFallback(.status(500)) { error in
            guard case APIError.httpError(statusCode: 500, body: _) = error else { return false }
            return true
        }
    }

    func testPreLogin_networkError_isSurfacedWithoutFallback() async throws {
        try await assertSurfacedWithoutFallback(.failure(URLError(.notConnectedToInternet))) { error in
            (error as? URLError)?.code == .notConnectedToInternet
        }
    }

    func testPreLogin_undecodableBody_isSurfacedWithoutFallback() async throws {
        try await assertSurfacedWithoutFallback(.status(200, body: Data("<html>".utf8))) { error in
            (error as? APIError) == .decodingFailed
        }
    }

    private func assertSurfacedWithoutFallback(
        _ primary: StubURLProtocol.Response,
        file: StaticString = #filePath, line: UInt = #line,
        matches: (Error) -> Bool
    ) async throws {
        answer(primary: primary, legacy: .status(200, body: vaultwarden1354Body))
        do {
            _ = try await sut.preLogin(email: email)
            XCTFail("Expected the primary route's failure", file: file, line: line)
        } catch {
            XCTAssertTrue(matches(error), "Unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "No fallback request", file: file, line: line)
    }

    // MARK: - 1.5 Both response shapes decode as today

    func testResponses_fromVaultwardenAndBitwarden_decode() throws {
        let current = try JSONDecoder().decode(PreLoginResponse.self, from: vaultwarden1374Body)
        XCTAssertEqual(current.kdfParams, KdfParams(type: .pbkdf2, iterations: 600_000, memory: nil, parallelism: nil))

        let older = try JSONDecoder().decode(PreLoginResponse.self, from: vaultwarden1354Body)
        XCTAssertEqual(older.kdfParams, KdfParams(type: .argon2id, iterations: 3, memory: 64, parallelism: 4))

        let bitwarden = try JSONDecoder().decode(PreLoginResponse.self, from: bitwardenBody)
        XCTAssertEqual(bitwarden.kdfParams, KdfParams(type: .pbkdf2, iterations: 600_000, memory: nil, parallelism: nil))
    }
}
