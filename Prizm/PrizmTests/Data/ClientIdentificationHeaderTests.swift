import XCTest
@testable import Prizm

/// Prizm identifies itself to the server as a macOS desktop client on every request, and sends
/// nothing of that to other hosts (openspec change client-identification-headers).
final class ClientIdentificationHeaderTests: XCTestCase {

    private var client: PrizmAPIClientImpl!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        await client.setAccessToken("token")
    }

    private func respond(_ json: String) {
        StubURLProtocol.responder = { _ in .status(200, body: Data(json.utf8)) }
    }

    private func assertIdentified(_ request: StubURLProtocol.RecordedRequest?, file: StaticString = #filePath, line: UInt = #line) {
        let headers = request?.headers ?? [:]
        XCTAssertEqual(headers["Device-Type"], "7", file: file, line: line)
        XCTAssertEqual(headers["Bitwarden-Client-Name"], "desktop", file: file, line: line)
        XCTAssertEqual(headers["Bitwarden-Client-Version"], "2024.12.0", file: file, line: line)
        XCTAssertNil(headers["X-Client-Version"], "Read by no server, sent by no official client", file: file, line: line)
        XCTAssertEqual(headers["User-Agent"], Config.userAgent, file: file, line: line)
        XCTAssertFalse(headers["User-Agent"]?.contains(Config.bitwardenClientVersion) ?? true,
                       "The user agent shows Prizm's version, not the Bitwarden one", file: file, line: line)
    }

    // MARK: - 1.1 Every request to the configured server

    func testPreLogin_isIdentified() async throws {
        respond(#"{"kdf":0,"kdfIterations":600000}"#)
        _ = try await client.preLogin(email: "a@example.com")
        assertIdentified(StubURLProtocol.requests.first)
    }

    func testTokenAndRefresh_areIdentified() async throws {
        respond(#"{"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_in":3600,"Key":"2.k|k|k"}"#)
        _ = try? await client.identityToken(email: "a@example.com", passwordHash: "h", deviceIdentifier: "d",
                                            twoFactorToken: nil, twoFactorProvider: nil, twoFactorRemember: false)
        _ = try? await client.refreshAccessToken(refreshToken: "rt")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        StubURLProtocol.requests.forEach { assertIdentified($0) }
        // D4: a deliberate difference from the official desktop app ("macos").
        let tokenForm = String(data: StubURLProtocol.requests.first?.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(tokenForm.contains("deviceName=Prizm"), tokenForm)
    }

    func testSyncAndCipherWrites_areIdentified() async throws {
        respond("{}")
        _ = try? await client.fetchSync()
        _ = try? await client.createAttachmentMetadata(
            cipherId: "c1", body: AttachmentMetadataRequest(fileName: "2.n|n|n", key: "2.k|k|k", fileSize: 1, adminRequest: false))
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        StubURLProtocol.requests.forEach { assertIdentified($0) }
    }

    // MARK: - 1.3 Other hosts get none of it

    func testBlobRequests_carryNoIdentificationOrToken() async throws {
        respond("")
        _ = try? await client.downloadBlob(from: URL(string: "https://blob.example.net/file?sig=x")!)
        try? await client.uploadAttachmentAzure(signedURL: URL(string: "https://blob.example.net/up?sig=x")!,
                                                encryptedBlob: Data([1, 2, 3]))

        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        for request in StubURLProtocol.requests {
            for name in ["Device-Type", "Bitwarden-Client-Name", "Bitwarden-Client-Version", "Authorization"] {
                XCTAssertNil(request.headers[name], "\(name) must not go to \(request.url?.host ?? "?")")
            }
        }
    }

    // MARK: - 1.2 An honest user agent

    func testUserAgent_namesPrizmAndMacOS() {
        let agent = Config.userAgent(appVersion: "1.5.0",
                                     osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0))
        XCTAssertEqual(agent, "Prizm/1.5.0 (macOS 15.1.0)")
    }
}
