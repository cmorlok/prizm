import XCTest
@testable import Prizm

/// Collection permissions from `/sync` and the collections request of an org save (openspec change
/// `fix-collection-assignment`, design D1, D5 and D5a).
final class CipherCollectionsEndpointTests: XCTestCase {

    private let base = URL(string: "https://vault.example.com")!
    private var sut: PrizmAPIClientImpl!

    private let cipherJSON = #"{"id":"c1","type":1,"name":"2.x|y|z","favorite":false,"collectionIds":["col-a","col-c"],"revisionDate":"2026-10-26T10:00:00.123456Z","deletedDate":null}"#

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        sut = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await sut.setBaseURL(base)
    }

    private let v2Path = "/api/ciphers/c1/collections_v2"
    private let legacyPath = "/api/ciphers/c1/collections"

    private func answer(v2: StubURLProtocol.Response, legacy: StubURLProtocol.Response = .status(500)) {
        let v2Path = v2Path
        StubURLProtocol.responder = { request in request.url?.path == v2Path ? v2 : legacy }
    }

    // MARK: - D1 Permissions

    func testRawCollection_decodesPermissions_bothCasings_missingIsFalse() throws {
        let camel = try JSONDecoder().decode(RawCollection.self, from: Data(
            #"{"id":"a","organizationId":"o","name":"2.n","readOnly":true,"hidePasswords":true,"manage":true}"#.utf8))
        XCTAssertEqual([camel.readOnly, camel.hidePasswords, camel.manage], [true, true, true])

        let pascal = try JSONDecoder().decode(RawCollection.self, from: Data(
            #"{"Id":"a","OrganizationId":"o","Name":"2.n","ReadOnly":true,"HidePasswords":false,"Manage":true}"#.utf8))
        XCTAssertEqual([pascal.readOnly, pascal.hidePasswords, pascal.manage], [true, false, true])

        let missing = try JSONDecoder().decode(RawCollection.self, from: Data(#"{"id":"a","organizationId":"o","name":"2.n"}"#.utf8))
        XCTAssertEqual([missing.readOnly, missing.hidePasswords, missing.manage], [false, false, false])
    }

    // MARK: - D5 collections_v2

    /// Vaultwarden 1.37.4 (`src/api/core/ciphers.rs:792-817`).
    func testCollectionsV2_sendsTheListAndReadsTheCipher() async throws {
        answer(v2: .status(200, body: Data(#"{"object":"optionalCipherDetails","unavailable":false,"cipher":\#(cipherJSON)}"#.utf8)))

        let result = try await sut.updateCipherCollections(id: "c1", collectionIds: ["col-a", "col-c"])

        XCTAssertFalse(result.unavailable)
        XCTAssertEqual(result.cipher?.collectionIds, ["col-a", "col-c"])
        XCTAssertEqual(result.cipher?.revisionDate, "2026-10-26T10:00:00.123456Z")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "The legacy route is never called when collections_v2 answers")
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url?.path, v2Path)
        XCTAssertEqual(request.jsonBody?["collectionIds"] as? [String], ["col-a", "col-c"])
    }

    func testCollectionsV2_unavailable() async throws {
        answer(v2: .status(200, body: Data(#"{"Unavailable":true,"Cipher":null}"#.utf8)))
        let result = try await sut.updateCipherCollections(id: "c1", collectionIds: ["col-a"])
        XCTAssertTrue(result.unavailable)
        XCTAssertNil(result.cipher)
    }

    func testCollectionsV2_emptyOrUnreadableBody_isASuccessWithoutCipher() async throws {
        for body in [Data(), Data("not json".utf8), Data(#"{"unavailable":false,"cipher":{"object":"cipher"}}"#.utf8)] {
            answer(v2: .status(200, body: body))
            let result = try await sut.updateCipherCollections(id: "c1", collectionIds: ["col-a"])
            XCTAssertFalse(result.unavailable)
            XCTAssertNil(result.cipher)
        }
    }

    // MARK: - D5a Legacy fallback

    func testLegacyFallback_on404WithEmptyBody() async throws {
        try await assertFallsBack(.status(404))
    }

    func testLegacyFallback_on405() async throws {
        try await assertFallsBack(.status(405, body: Data("Method Not Allowed".utf8)))
    }

    private func assertFallsBack(_ v2: StubURLProtocol.Response, file: StaticString = #filePath, line: UInt = #line) async throws {
        answer(v2: v2, legacy: .status(200, body: Data(cipherJSON.utf8)))

        let result = try await sut.updateCipherCollections(id: "c1", collectionIds: ["col-a", "col-c"])

        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, [v2Path, legacyPath], file: file, line: line)
        XCTAssertEqual(StubURLProtocol.requests.last?.method, "PUT", file: file, line: line)
        XCTAssertEqual(StubURLProtocol.requests.last?.jsonBody?["collectionIds"] as? [String], ["col-a", "col-c"], file: file, line: line)
        XCTAssertFalse(result.unavailable, file: file, line: line)
        XCTAssertEqual(result.cipher?.collectionIds, ["col-a", "col-c"], file: file, line: line)
    }

    func testNoFallback_on404WithErrorBody() async {
        answer(v2: .status(404, body: Data(#"{"message":"Resource not found.","object":"error"}"#.utf8)),
               legacy: .status(200, body: Data(cipherJSON.utf8)))
        do {
            _ = try await sut.updateCipherCollections(id: "c1", collectionIds: ["col-a"])
            XCTFail("A 404 with an error body must throw")
        } catch APIError.httpError(let status, _) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("Expected httpError, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, [v2Path], "No legacy request")
    }

    func testNoFallback_onOtherErrors() async {
        for status in [400, 500] {
            StubURLProtocol.reset()
            answer(v2: .status(status), legacy: .status(200, body: Data(cipherJSON.utf8)))
            do {
                _ = try await sut.updateCipherCollections(id: "c1", collectionIds: ["col-a"])
                XCTFail("\(status) must throw")
            } catch {}
            XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, [v2Path], "\(status): no legacy request")
        }
    }
}
