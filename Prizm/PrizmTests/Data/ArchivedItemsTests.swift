import XCTest
@testable import Prizm

/// Archive state (openspec change `archived-items`): decoding (tasks 2.1–2.2), lists (3.1–3.2),
/// lookups by id (3.4), the archive action (4.1–4.2) and older servers (4.4). Real crypto.
@MainActor
final class ArchivedItemsTests: XCTestCase {

    private let vaultKeys = KeyedCipherBuilder.randomKeys()
    private let mapper = CipherMapper()
    private static let archivedAt = "2026-10-26T19:06:49.281743Z"
    private static let laterRevision = "2026-10-30T10:00:00.123456Z"

    // MARK: - Helpers

    private func item(_ id: String, favorite: Bool = false, folderId: String? = nil,
                      deleted: Bool = false, totp: String? = nil) -> VaultItem {
        VaultItem(id: id, name: "Item \(id)", isFavorite: favorite, isDeleted: deleted,
                  creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate,
                  content: .login(LoginContent(username: "u", password: "p", uris: [], totp: totp,
                                               notes: nil, customFields: [])),
                  folderId: folderId)
    }

    /// The server record of `item`; `archivedDate` is set as given (`NSNull()` for null, nil absent).
    private func record(_ item: VaultItem, archivedDate: Any?) throws -> RawCipher {
        let created = try CipherMapper().toUnkeyedRawCipher(DraftVaultItem(item), encryptedWith: vaultKeys,
                                                        encryptedFor: RepositoryFixtures.profileId)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(created)) as? [String: Any])
        json["revisionDate"] = RepositoryFixtures.serverRevisionString(for: item.revisionDate)
        if item.isDeleted { json["deletedDate"] = "2026-10-01T00:00:00.000Z" }
        if let archivedDate { json["archivedDate"] = archivedDate }
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private struct Rig {
        let api: MockPrizmAPIClient
        let store: RawCipherStore
        let repository: VaultRepositoryImpl
    }

    /// A repository holding `records` both as stored records and as mapped, cached items.
    private func makeRig(_ records: [RawCipher]) async throws -> Rig {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys
        let store = RawCipherStore()
        let token = store.currentGeneration()
        _ = await store.replaceAll(records, ifCurrent: token)
        let repository = await RepositoryFixtures.vaultRepository(apiClient: api, crypto: crypto, recordStore: store)
        let items = try records.map { try mapper.map(raw: $0, vaultKeys: vaultKeys).item }
        await repository.populate(items: items, folders: [Folder(id: "f1", name: "Work")], organizations: [],
                                  collections: [], syncedAt: Date())
        return Rig(api: api, store: store, repository: repository)
    }

    private func ids(_ items: [VaultItem]) -> [String] { items.map(\.id).sorted() }

    /// What the server holds after the archive request: `stored` with the new archive state and
    /// revision, and `edit` applied (another client's change, say). Returned by the record fetch.
    private func serverRecord(_ stored: RawCipher, archivedDate: Any, revision: String,
                              edit: (inout [String: Any]) -> Void = { _ in }) throws -> RawCipher {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        json["archivedDate"] = archivedDate
        json["revisionDate"] = revision
        edit(&json)
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - 2.1/2.2 Decoding

    func testMap_archivedDate() throws {
        let plain = item("a")
        XCTAssertNil(try mapper.map(raw: record(plain, archivedDate: nil), vaultKeys: vaultKeys).item.archivedDate)
        XCTAssertNil(try mapper.map(raw: record(plain, archivedDate: NSNull()), vaultKeys: vaultKeys).item.archivedDate)
        let archived = try mapper.map(raw: record(plain, archivedDate: Self.archivedAt), vaultKeys: vaultKeys).item
        XCTAssertEqual(archived.archivedDate, CipherMapper.parseRevisionDate(Self.archivedAt))
        XCTAssertTrue(archived.isArchived)
        XCTAssertFalse(archived.isActive)
    }

    func testMap_unreadableArchivedDate_countsAsArchived() throws {
        for value in ["not a date", 42] as [Any] {
            let mapped = try mapper.map(raw: record(item("a"), archivedDate: value), vaultKeys: vaultKeys).item
            XCTAssertTrue(mapped.isArchived, "\(value)")
        }
    }

    func testBuilders_keepTheArchiveState() throws {
        let archived = try mapper.map(raw: record(item("a"), archivedDate: Self.archivedAt), vaultKeys: vaultKeys).item
        XCTAssertTrue(archived.with(folderId: "f1").isArchived)
        XCTAssertTrue(archived.with(isFavorite: true).isArchived)
        XCTAssertTrue(archived.with(revisionDate: Date()).isArchived)
        XCTAssertTrue(VaultItem(DraftVaultItem(archived)).isArchived, "an item built from its draft stays archived")
    }

    // MARK: - 3.1/3.2 Lists

    func testIndexes_archivedItemsLeaveEveryEverydayList() async throws {
        let rig = try await makeRig([
            try record(item("active", favorite: true, folderId: "f1", totp: "JBSWY3DPEHPK3PXP"), archivedDate: NSNull()),
            try record(item("archived", favorite: true, folderId: "f1", totp: "JBSWY3DPEHPK3PXP"), archivedDate: Self.archivedAt),
            try record(item("archivedDeleted", deleted: true), archivedDate: Self.archivedAt),
            try record(item("deleted", deleted: true), archivedDate: nil),
        ])
        let repo = rig.repository
        for selection in [SidebarSelection.allItems, .favorites, .type(.login), .folder("f1"), .verificationCodes] {
            let listed = try await repo.items(for: selection)
            XCTAssertEqual(ids(listed), ["active"], "\(selection)")
        }
        let archive = try await repo.items(for: .archive)
        XCTAssertEqual(ids(archive), ["archived"])
        let trash = try await repo.items(for: .trash)
        XCTAssertEqual(ids(trash), ["archivedDeleted", "deleted"])
        let counts = try await repo.itemCounts()
        XCTAssertEqual(counts[.allItems], 1)
        XCTAssertEqual(counts[.archive], 1)
        XCTAssertEqual(counts[.trash], 2)
    }

    func testSearch_findsArchivedItemsOnlyInsideArchive() async throws {
        let rig = try await makeRig([try record(item("archived"), archivedDate: Self.archivedAt)])
        let inArchive = try await rig.repository.searchItems(query: "Item", in: .archive)
        let elsewhere = try await rig.repository.searchItems(query: "Item", in: .allItems)
        XCTAssertEqual(ids(inArchive), ["archived"])
        XCTAssertEqual(elsewhere, [])
    }

    func testSelection_archiveEqualsItselfAndHashesApart() {
        XCTAssertEqual(SidebarSelection.archive, .archive)
        XCTAssertNotEqual(SidebarSelection.archive, .trash)
        XCTAssertNotEqual(SidebarSelection.archive.hashValue, SidebarSelection.trash.hashValue)
        XCTAssertEqual(SidebarSelection.archive.displayName, "Archive")
    }

    // MARK: - 3.4 Lookups by id see archived items

    func testItemDetail_findsArchivedItems() async throws {
        let rig = try await makeRig([try record(item("archived"), archivedDate: Self.archivedAt)])
        let found = try await rig.repository.itemDetail(id: "archived")
        XCTAssertTrue(found.isArchived)
    }

    // MARK: - 4.1/4.2 Archive and unarchive

    func testArchive_sendsTheRequestAndMovesTheItem() async throws {
        let stored = try record(item("a"), archivedDate: NSNull())
        let rig = try await makeRig([stored])
        rig.api.archiveAnswer = ArchiveStateAnswer(archivedDate: .string(Self.archivedAt), revisionDate: Self.laterRevision)
        rig.api.getCipherResponses["a"] = try serverRecord(stored, archivedDate: Self.archivedAt, revision: Self.laterRevision)

        try await rig.repository.setArchived(id: "a", archived: true)

        XCTAssertEqual(rig.api.archiveRequests.map(\.archived), [true])
        let all = try await rig.repository.items(for: .allItems)
        let archive = try await rig.repository.items(for: .archive)
        XCTAssertEqual(all, [])
        XCTAssertEqual(ids(archive), ["a"])
        // The stored record is the server's, fetched after the request.
        let record = await rig.store.record(for: "a")
        XCTAssertEqual(record?.archivedDate, .string(Self.archivedAt))
        XCTAssertEqual(record?.revisionDate, Self.laterRevision)
        XCTAssertEqual(record?.name, stored.name)
        let cached = try await rig.repository.itemDetail(id: "a")
        XCTAssertEqual(cached.revisionDate, CipherMapper.parseRevisionDate(Self.laterRevision))
    }

    func testUnarchive_movesTheItemBack() async throws {
        let stored = try record(item("a"), archivedDate: Self.archivedAt)
        let rig = try await makeRig([stored])
        rig.api.archiveAnswer = ArchiveStateAnswer(archivedDate: .null, revisionDate: Self.laterRevision)
        rig.api.getCipherResponses["a"] = try serverRecord(stored, archivedDate: NSNull(), revision: Self.laterRevision)

        try await rig.repository.setArchived(id: "a", archived: false)

        XCTAssertEqual(rig.api.archiveRequests.map(\.archived), [false])
        let all = try await rig.repository.items(for: .allItems)
        XCTAssertEqual(ids(all), ["a"])
        let record = await rig.store.record(for: "a")
        XCTAssertEqual(record?.archivedDate, .null)
    }

    func testArchive_thenEdit_sendsTheNewStateAndNoConflict() async throws {
        let stored = try record(item("a"), archivedDate: NSNull())
        let rig = try await makeRig([stored])
        rig.api.archiveAnswer = ArchiveStateAnswer(archivedDate: .string(Self.archivedAt), revisionDate: Self.laterRevision)
        rig.api.getCipherResponses["a"] = try serverRecord(stored, archivedDate: Self.archivedAt, revision: Self.laterRevision)
        try await rig.repository.setArchived(id: "a", archived: true)

        var draft = DraftVaultItem(try await rig.repository.itemDetail(id: "a"))
        draft.name = "Edited"
        RepositoryFixtures.answerUpdates(of: rig.api, withRevisionString: "2026-10-30T11:00:00.000000Z")
        _ = try await rig.repository.update(draft)

        XCTAssertEqual(rig.api.lastUpdatedCipher?.archivedDate, .string(Self.archivedAt), "the edit keeps the item archived")
        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, Self.laterRevision)
    }

    func testArchive_afterAnotherClientsEdit_keepsTheConflictCheck() async throws {
        // Client B edited the item (the server is ahead), then Prizm archives it. Taking the
        // answer's revision would let the next save overwrite B's edit without a conflict.
        let stored = try record(item("a"), archivedDate: NSNull())
        let rig = try await makeRig([stored])
        rig.api.archiveAnswer = ArchiveStateAnswer(archivedDate: .string(Self.archivedAt), revisionDate: Self.laterRevision)
        rig.api.getCipherResponses["a"] = try serverRecord(stored, archivedDate: Self.archivedAt,
                                                           revision: Self.laterRevision) { json in
            json["name"] = KeyedCipherBuilder.encrypt("Renamed by B", keys: self.vaultKeys)
        }

        try await rig.repository.setArchived(id: "a", archived: true)

        let cached = try await rig.repository.itemDetail(id: "a")
        XCTAssertEqual(cached.revisionDate, RepositoryFixtures.revisionDate,
                       "the cached revision stays behind, so the next save meets the conflict")
        XCTAssertTrue(cached.isArchived, "the item still moves to Archive")
    }

    func testArchive_answerWithoutState_fetchesTheRecord() async throws {
        let stored = try record(item("a"), archivedDate: NSNull())
        let rig = try await makeRig([stored])
        rig.api.archiveAnswer = nil
        var fetched = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        fetched["archivedDate"] = Self.archivedAt
        fetched["revisionDate"] = Self.laterRevision
        rig.api.getCipherResponses["a"] = try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: fetched))

        try await rig.repository.setArchived(id: "a", archived: true)

        let archive = try await rig.repository.items(for: .archive)
        XCTAssertEqual(ids(archive), ["a"])
        let cached = try await rig.repository.itemDetail(id: "a")
        XCTAssertEqual(cached.revisionDate, CipherMapper.parseRevisionDate(Self.laterRevision),
                       "the fetched record is not read as changed elsewhere")
    }

    /// Spec scenario "Restoring an archived item from Trash": it leaves Trash for Archive, not for
    /// All Items (verify 2026-10-31).
    func testRestoreFromTrash_keepsTheItemArchived() async throws {
        let stored = try record(item("a", deleted: true), archivedDate: Self.archivedAt)
        let rig = try await makeRig([stored])
        var restored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        restored["deletedDate"] = NSNull()
        restored["revisionDate"] = Self.laterRevision
        rig.api.restoreCipherResponse = try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: restored))

        try await rig.repository.restoreItem(id: "a")

        let archive = try await rig.repository.items(for: .archive)
        let all = try await rig.repository.items(for: .allItems)
        let trash = try await rig.repository.items(for: .trash)
        XCTAssertEqual(ids(archive), ["a"])
        XCTAssertEqual(all, [])
        XCTAssertEqual(trash, [])
    }

    /// Task 4.2: an archive change made elsewhere and found by the refresh after an own write (here
    /// a favourite) reaches the lists (verify 2026-10-31).
    func testRefreshAfterAFavorite_bringsAnArchiveChangeMadeElsewhere() async throws {
        let stored = try record(item("a"), archivedDate: NSNull())
        let rig = try await makeRig([stored])
        rig.api.getCipherResponses["a"] = try serverRecord(stored, archivedDate: Self.archivedAt,
                                                           revision: RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate))

        _ = try await rig.repository.setFavorite(itemId: "a", isFavorite: true)

        let archive = try await rig.repository.items(for: .archive)
        let all = try await rig.repository.items(for: .allItems)
        XCTAssertEqual(ids(archive), ["a"])
        XCTAssertEqual(all, [])
    }

    /// The refresh finds the item changed elsewhere (the cached revision stays for the conflict
    /// check), but the archive state made elsewhere still reaches the lists.
    func testRefreshFindingAnotherEdit_stillAppliesTheArchiveState() async throws {
        let stored = try record(item("a"), archivedDate: NSNull())
        let rig = try await makeRig([stored])
        rig.api.getCipherResponses["a"] = try serverRecord(stored, archivedDate: Self.archivedAt,
                                                           revision: Self.laterRevision) { json in
            json["name"] = KeyedCipherBuilder.encrypt("Renamed by B", keys: self.vaultKeys)
        }

        _ = try await rig.repository.setFavorite(itemId: "a", isFavorite: true)

        let archive = try await rig.repository.items(for: .archive)
        XCTAssertEqual(ids(archive), ["a"])
        let cached = try await rig.repository.itemDetail(id: "a")
        XCTAssertEqual(cached.revisionDate, RepositoryFixtures.revisionDate, "the conflict check stays")
    }

    func testArchive_lockDuringTheRequest_changesNothing() async throws {
        let rig = try await makeRig([try record(item("a"), archivedDate: NSNull())])
        rig.api.archiveAnswer = ArchiveStateAnswer(archivedDate: .string(Self.archivedAt), revisionDate: Self.laterRevision)
        rig.api.whileArchiving = { [store = rig.store] in store.invalidate() }

        do {
            try await rig.repository.setArchived(id: "a", archived: true)
            XCTFail("Expected vaultLocked")
        } catch VaultError.vaultLocked {
            // expected
        }
        let record = await rig.store.record(for: "a")
        XCTAssertEqual(record?.archivedDate, .null)
    }

    // MARK: - 4.4 Older servers

    func testArchive_404WithoutMessage_isUnsupported_withMessage_isTheServers() async throws {
        let rig = try await makeRig([try record(item("a"), archivedDate: NSNull())])
        rig.api.archiveShouldThrow = APIError.httpError(statusCode: 404, body: "")
        do {
            try await rig.repository.setArchived(id: "a", archived: true)
            XCTFail("Expected archiveUnsupported")
        } catch VaultError.archiveUnsupported {
            XCTAssertEqual(VaultError.archiveUnsupported.errorDescription, "This server doesn't support archiving items.")
        }

        rig.api.archiveShouldThrow = APIError.httpError(statusCode: 404, body: #"{"message":"Cipher doesn't exist"}"#)
        do {
            try await rig.repository.setArchived(id: "a", archived: true)
            XCTFail("Expected the server's error")
        } catch let error as APIError {
            XCTAssertEqual(error.errorDescription, "Cipher doesn't exist")
        }
        let all = try await rig.repository.items(for: .allItems)
        XCTAssertEqual(ids(all), ["a"], "the item stays where it was")
    }

    func testSupport_detectedFromTheStoredRecords() async throws {
        let modern = try await makeRig([try record(item("a"), archivedDate: NSNull())])
        let modernSupported = await modern.repository.isArchiveSupported()
        XCTAssertTrue(modernSupported)
        let legacy = try await makeRig([try record(item("a"), archivedDate: nil)])
        let legacySupported = await legacy.repository.isArchiveSupported()
        XCTAssertFalse(legacySupported, "no record has the key")
        let empty = try await makeRig([])
        let emptySupported = await empty.repository.isArchiveSupported()
        XCTAssertTrue(emptySupported, "an empty vault counts as supported")
    }

    func testLegacyServer_listsAreUnchanged() async throws {
        let rig = try await makeRig([try record(item("a"), archivedDate: nil), try record(item("b", favorite: true), archivedDate: nil)])
        let all = try await rig.repository.items(for: .allItems)
        XCTAssertEqual(ids(all), ["a", "b"])
        let counts = try await rig.repository.itemCounts()
        XCTAssertEqual(counts[.archive], 0)
    }
}

/// The archive request itself (archived-items, task 4.1).
final class ArchiveRequestTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
    }

    private func client() async -> PrizmAPIClientImpl {
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        await client.setAccessToken("token-1")
        return client
    }

    func testArchiveAndUnarchive_putToTheirPathsWithoutABody() async throws {
        StubURLProtocol.responder = { _ in .status(200) }
        let client = await client()

        _ = try await client.setCipherArchived(id: "a", archived: true)
        _ = try await client.setCipherArchived(id: "a", archived: false)

        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["PUT", "PUT"])
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/api/ciphers/a/archive", "/api/ciphers/a/unarchive"])
        XCTAssertNil(StubURLProtocol.requests[0].jsonBody)
        XCTAssertEqual(StubURLProtocol.requests[0].headers["Authorization"], "Bearer token-1")
    }

    func testAnswer_keepsNullApartFromAbsent() async throws {
        let bodies = [#"{"archivedDate":"2026-10-26T19:06:49.281743Z","revisionDate":"r"}"#,
                      #"{"archivedDate":null}"#, #"{"object":"cipherMini"}"#]
        let expected: [JSONValue?] = [.string("2026-10-26T19:06:49.281743Z"), .null, nil]
        for (body, state) in zip(bodies, expected) {
            StubURLProtocol.responder = { _ in .status(200, body: Data(body.utf8)) }
            let answer = try await client().setCipherArchived(id: "a", archived: true)
            XCTAssertEqual(answer?.archivedDate, state, body)
        }
    }
}
