import XCTest
@testable import Prizm

/// After Prizm's own operations the stored record and the cached item's revision are the server's
/// again, so the next edit passes the revision pre-check and is not rejected as a conflict
/// (openspec change fix-cipher-edit-data-loss, task 4.4).
///
/// The mock API answers a refresh from `getCipherResponses`; an id without an entry throws, which
/// is the failed refresh every older test sees.
@MainActor
final class RevisionRefreshTests: XCTestCase {

    // Three server revisions, each a whole millisecond apart from the others by a minute.
    private static let r1 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate)
    private static let r2 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(60))
    private static let r3 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(120))

    // MARK: - Tracer: delete, restore, then edit

    func testDeleteRestoreEdit_savesWithoutConflict() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        rig.api.restoreCipherResponse = try await record("c1", in: rig, revision: Self.r3)

        try await rig.vault.deleteItem(id: "c1")
        try await rig.vault.restoreItem(id: "c1")

        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r3, "The stored record is the restore answer, byte for byte")
        let cached = try await rig.vault.itemDetail(id: "c1")
        try assertRevision(cached.revisionDate, is: Self.r3)

        var draft = DraftVaultItem(cached)
        draft.name = "Renamed after restore"
        _ = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The edit passes the pre-check and is sent")
        XCTAssertEqual(rig.api.callLog, ["delete c1", "GET c1", "restore c1", "PUT c1"],
                       "Delete is refreshed with a fetch; the restore answer needs none")
    }

    func testSoftDelete_refreshesWithGet() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)

        try await rig.vault.deleteItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"], "One GET for the item")
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r2, "The stored record is the GET answer")
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertTrue(cached.isDeleted)
        try assertRevision(cached.revisionDate, is: Self.r2)
        let trashed = try await rig.vault.items(for: .trash)
        XCTAssertEqual(trashed.map(\.id), ["c1"], "The index shows the refreshed item")
    }

    func testRestore_usesTheResponseCipher() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await seed([item], in: rig)
        rig.api.restoreCipherResponse = try await record("c1", in: rig, revision: Self.r3)

        try await rig.vault.restoreItem(id: "c1")

        XCTAssertTrue(rig.api.getCipherCalls.isEmpty, "A restore answer that carries the cipher needs no GET")
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r3)
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertFalse(cached.isDeleted)
        try assertRevision(cached.revisionDate, is: Self.r3)
    }

    func testRestoreWithoutCipher_refreshesWithGet() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await seed([item], in: rig)
        rig.api.restoreCipherResponse = nil
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)

        try await rig.vault.restoreItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"])
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r2)
        let cached = try await rig.vault.itemDetail(id: "c1")
        try assertRevision(cached.revisionDate, is: Self.r2)
    }

    // MARK: - The answer must be for the item that was asked about

    /// The store and the cached items are keyed by the id the sync delivered. An answer that names
    /// the item in another case would open a second store entry and leave the record the next save
    /// reads as it was, so it is ignored like an answer for another item.
    func testRefreshAnswerWithAnIdInAnotherCase_isIgnored() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record(
            "c1", in: rig, revision: Self.r2, replacing: ["id": "C1"])

        try await rig.vault.deleteItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"])
        let upperCase = await rig.store.record(for: "C1")
        XCTAssertNil(upperCase, "No second entry under the answer's id")
        let count = await rig.store.count
        XCTAssertEqual(count, 1)
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r1, "The stored record is unchanged")
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertTrue(cached.isDeleted, "The operation itself took effect")
        try assertRevision(cached.revisionDate, is: Self.r1)
    }

    // MARK: - A failed refresh never fails the operation

    func testFailedRefresh_operationSucceedsAndKeepsTheOldRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherShouldThrow = APIError.httpError(statusCode: 500, body: "secret body")

        try await rig.vault.deleteItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"])
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, Self.r1, "The stored record is unchanged")
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertTrue(cached.isDeleted, "The operation itself took effect")
        try assertRevision(cached.revisionDate, is: Self.r1)
    }

    /// An answer that decodes as a cipher but carries no readable revision does not replace the
    /// stored record: the next edit would otherwise be refused for a missing revision.
    func testRefreshAnswerWithoutReadableRevision_keepsTheStoredRecord() async throws {
        let unreadable: [(label: String, value: Any)] = [
            ("missing", NSNull()), ("empty", ""), ("unparsable", "not-a-date"), ("epoch", "1970-01-01T00:00:00.000Z"),
        ]
        for revision in unreadable {
            let rig = await StaleWriteRig.make()
            let item = StaleWriteRig.login("c1").with(isDeleted: true)
            try await seed([item], in: rig)
            rig.api.restoreCipherResponse = try await record(
                "c1", in: rig, revision: Self.r2, replacing: ["revisionDate": revision.value])

            try await rig.vault.restoreItem(id: "c1")

            let stored = await rig.store.record(for: "c1")
            XCTAssertEqual(stored?.revisionDate, Self.r1, "\(revision.label): the stored record is kept")
            let cached = try await rig.vault.itemDetail(id: "c1")
            XCTAssertFalse(cached.isDeleted, "\(revision.label): the restore itself took effect")
            try assertRevision(cached.revisionDate, is: Self.r1)

            var draft = DraftVaultItem(cached)
            draft.name = "Renamed after restore"
            _ = try await rig.vault.update(draft)
            XCTAssertEqual(rig.api.updateCipherCallCount, 1, "\(revision.label): the next edit is sent")
        }
    }

    // MARK: - Lock

    func testRefreshFinishingAfterLock_writesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        let vault = rig.vault
        rig.api.whileGettingCipher = { await vault.clearVault() }

        try await rig.vault.deleteItem(id: "c1")

        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "The refresh does not refill the record store after the lock")
        let cached = try await rig.vault.allItems()
        XCTAssertTrue(cached.isEmpty, "Nor the item list")
        let trashed = try await rig.vault.items(for: .trash)
        XCTAssertTrue(trashed.isEmpty)
    }

    /// A restore whose answer carries no cipher refreshes with a GET; a lock that lands during that
    /// GET must leave no record and no item behind. (`deleteItem` is covered above; the refreshing
    /// operations share `refreshRecord` but not its call site.)
    func testRestoreRefreshFinishingAfterLock_writesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await seed([item], in: rig)
        rig.api.restoreCipherResponse = nil
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)
        let vault = rig.vault
        rig.api.whileGettingCipher = { await vault.clearVault() }

        try await rig.vault.restoreItem(id: "c1")

        XCTAssertEqual(rig.api.getCipherCalls, ["c1"], "The refresh did start")
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "The refresh does not refill the record store after the lock")
        let cached = try await rig.vault.allItems()
        XCTAssertTrue(cached.isEmpty, "Nor the item list")
    }

    // MARK: - Idempotency

    func testRefreshTwice_isIdempotent() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await seed([item], in: rig)
        rig.api.getCipherResponses["c1"] = try await record("c1", in: rig, revision: Self.r2)

        try await rig.vault.deleteItem(id: "c1")
        let firstRecord = try await encodedRecord("c1", in: rig)
        let firstRevision = try await rig.vault.itemDetail(id: "c1").revisionDate
        try await rig.vault.deleteItem(id: "c1")
        let secondRecord = try await encodedRecord("c1", in: rig)
        let secondRevision = try await rig.vault.itemDetail(id: "c1").revisionDate

        XCTAssertEqual(rig.api.getCipherCalls, ["c1", "c1"])
        XCTAssertEqual(firstRecord, secondRecord, "The same answer leaves the same stored record")
        XCTAssertEqual(firstRevision, secondRevision, "and the same cached revision")
        try assertRevision(secondRevision, is: Self.r2)
    }

    // MARK: - Adjacency

    func testRestoreThenEditInTheSameSecond_storesTheRestoreRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await seed([item], in: rig)
        // Same second as the seeded revision; only the fraction differs.
        let sameSecond = RepositoryFixtures.serverRevisionString(
            for: RepositoryFixtures.revisionDate.addingTimeInterval(0.5))
        XCTAssertNotEqual(sameSecond, Self.r1)
        XCTAssertEqual(sameSecond.prefix(19), Self.r1.prefix(19), "Both revisions are in the same second")
        rig.api.restoreCipherResponse = try await record("c1", in: rig, revision: sameSecond)

        try await rig.vault.restoreItem(id: "c1")

        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, sameSecond, "The restore answer's string, byte for byte; no time tolerance")
        let cached = try await rig.vault.itemDetail(id: "c1")
        var draft = DraftVaultItem(cached)
        draft.name = "Renamed in the same second"
        _ = try await rig.vault.update(draft)
        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The pre-check passes and the PUT is sent")
    }

    // MARK: - A refresh never decrypts

    func testRefresh_storesAnUnreadableRecordAndPatchesOnlyTheRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1", name: "Original")
        try await seed([item], in: rig)
        // A record no key can read: if the refresh decrypted or mapped it, the name would change or
        // the operation would fail.
        let unreadable = try await record("c1", in: rig, revision: Self.r2, replacing: ["name": "2.AAAA|BBBB|CCCC"])
        rig.api.getCipherResponses["c1"] = unreadable

        try await rig.vault.deleteItem(id: "c1")

        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.name, "2.AAAA|BBBB|CCCC", "The record is stored as received")
        let cached = try await rig.vault.itemDetail(id: "c1")
        XCTAssertEqual(cached.name, "Original", "Nothing was mapped: the cached item keeps its decrypted name")
        try assertRevision(cached.revisionDate, is: Self.r2)
    }

    // MARK: - Helpers

    /// Stores and caches `items` as a sync would leave them (revision `r1` for the default login).
    private func seed(_ items: [VaultItem], in rig: StaleWriteRig) async throws {
        for item in items {
            try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        }
        await rig.vault.populate(items: items, folders: [Folder(id: "work", name: "Work")],
                                 organizations: [], collections: [], syncedAt: Date())
    }

    /// The stored record of `id` with another `revisionDate` (and optionally other top-level
    /// values), as a server answer.
    private func record(
        _ id: String, in rig: StaleWriteRig, revision: String, replacing changes: [String: Any] = [:]
    ) async throws -> RawCipher {
        let stored = await rig.store.record(for: id)
        let data = try JSONEncoder().encode(try XCTUnwrap(stored))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["revisionDate"] = revision
        for (key, value) in changes { json[key] = value }
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The stored record as sorted-key JSON, to compare two states of it.
    private func encodedRecord(_ id: String, in rig: StaleWriteRig) async throws -> Data {
        let stored = await rig.store.record(for: id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(try XCTUnwrap(stored))
    }

    private func assertRevision(
        _ date: Date, is revision: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let expected = try XCTUnwrap(CipherMapper.parseRevisionDate(revision), file: file, line: line)
        XCTAssertTrue(CipherMapper.sameRevision(date, expected),
                      "cached revision \(date) is not \(revision)", file: file, line: line)
    }
}

// MARK: - The wire: GET one cipher, restore with and without an answer

/// `getCipher` and the cipher-returning `restoreCipher` of the real client, at the HTTP level.
final class RevisionRefreshWireTests: XCTestCase {

    private let base = URL(string: "https://vault.example.com")!
    private var sut: PrizmAPIClientImpl!

    private let cipherBody = Data("""
        {"id":"c1","type":1,"name":"2.x|y|z","favorite":false,
         "revisionDate":"2026-10-26T10:00:00.123456Z","deletedDate":null}
        """.utf8)

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        sut = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await sut.setBaseURL(base)
    }

    func testGetCipher_sendsGetToTheItemRouteAndDecodesTheCipher() async throws {
        StubURLProtocol.responder = { [cipherBody] _ in .status(200, body: cipherBody) }

        let cipher = try await sut.getCipher(id: "c1")

        XCTAssertEqual(cipher.id, "c1")
        XCTAssertEqual(cipher.revisionDate, "2026-10-26T10:00:00.123456Z", "The revision string is kept as received")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://vault.example.com/api/ciphers/c1")
        XCTAssertNil(request.body)
    }

    func testGetCipher_httpErrorThrows() async {
        StubURLProtocol.responder = { _ in .status(404) }

        do {
            _ = try await sut.getCipher(id: "c1")
            XCTFail("A 404 must throw")
        } catch APIError.httpError(let status, _) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("Expected httpError, got \(error)")
        }
    }

    /// The fetch runs inside the item's write queue, so a server that stops answering must free the
    /// queue well before the session's default time-out of 60 seconds.
    func testGetCipher_hasAShortTimeoutOfItsOwn() async throws {
        StubURLProtocol.responder = { [cipherBody] _ in .status(200, body: cipherBody) }

        _ = try await sut.getCipher(id: "c1")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.timeoutInterval, PrizmAPIClientImpl.revisionRefreshTimeout)
        XCTAssertLessThanOrEqual(PrizmAPIClientImpl.revisionRefreshTimeout, 10)
    }

    func testRestoreCipher_returnsTheCipherTheServerSent() async throws {
        StubURLProtocol.responder = { [cipherBody] _ in .status(200, body: cipherBody) }

        let restored = try await sut.restoreCipher(id: "c1")

        XCTAssertEqual(restored?.revisionDate, "2026-10-26T10:00:00.123456Z")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url?.path, "/api/ciphers/c1/restore")
        XCTAssertNil(request.body, "No body: a body with a Content-Type makes Vaultwarden answer 400")
        XCTAssertNil(request.headers["Content-Type"])
    }

    func testRestoreCipher_emptyOrUndecodableBodyGivesNilNotAnError() async throws {
        for body in [Data(), Data("not json".utf8), Data("{\"object\":\"cipher\"}".utf8)] {
            StubURLProtocol.responder = { _ in .status(200, body: body) }

            let restored = try await sut.restoreCipher(id: "c1")

            XCTAssertNil(restored, "A restore that succeeded is a success whatever the body holds")
        }
    }

    func testRestoreCipher_httpErrorStillThrows() async {
        StubURLProtocol.responder = { _ in .status(503) }

        do {
            _ = try await sut.restoreCipher(id: "c1")
            XCTFail("A 503 must throw")
        } catch APIError.httpError(let status, _) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("Expected httpError, got \(error)")
        }
    }
}
