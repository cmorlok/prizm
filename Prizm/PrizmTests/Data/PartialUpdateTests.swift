import XCTest
@testable import Prizm

/// Favorite and folder changes are sent as partial updates and never alter other item data, on
/// the server or in the local cache (openspec change fix-favorite-and-folder-partial-updates).
@MainActor
final class PartialUpdateTests: XCTestCase {

    private var sut: VaultRepositoryImpl!
    private var mockAPI: MockPrizmAPIClient!
    private var mockCrypto: MockPrizmCryptoService!
    private var orgKeyCache: OrgKeyCache!
    private var recordStore: RawCipherStore!

    private let vaultKeys = CryptoKeys(encryptionKey: Data(repeating: 0x11, count: 32), macKey: Data(repeating: 0x22, count: 32))
    private let orgKeys = CryptoKeys(encryptionKey: Data(repeating: 0x33, count: 32), macKey: Data(repeating: 0x44, count: 32))
    private let revision = Date(timeIntervalSince1970: 1_700_000_000)

    /// An org item with every field the local rebuilds used to drop.
    private lazy var orgItem = VaultItem(
        id: "org-item", name: "Shared Login", isFavorite: false, isDeleted: false,
        creationDate: Date(timeIntervalSince1970: 1_600_000_000), revisionDate: revision,
        content: .login(LoginContent(username: "team", password: "pw", uris: [], totp: nil, notes: nil, customFields: [])),
        reprompt: 1,
        attachments: [Attachment(id: "att-1", fileName: "a.txt", encryptedKey: "2.k|k|k", size: 10,
                                 sizeName: "10 B", url: nil, isUploadIncomplete: false)],
        folderId: "old-folder",
        organizationId: "org-1",
        collectionIds: ["col-a"]
    )

    override func setUp() async throws {
        try await super.setUp()
        mockAPI = MockPrizmAPIClient()
        mockCrypto = MockPrizmCryptoService()
        orgKeyCache = OrgKeyCache()
        recordStore = RawCipherStore()
        sut = await RepositoryFixtures.vaultRepository(
            apiClient: mockAPI, crypto: mockCrypto, orgKeyCache: orgKeyCache, recordStore: recordStore)
        await sut.populate(items: [orgItem], folders: [Folder(id: "old-folder", name: "Old"), Folder(id: "work", name: "Work")],
                           organizations: [], collections: [], syncedAt: Date())
    }

    private func cached() async throws -> VaultItem {
        try await sut.itemDetail(id: orgItem.id)
    }

    // MARK: - 1.2 Local rebuilds keep every field

    func testMoveItemToFolder_keepsEveryOtherField() async throws {
        try await sut.moveItemToFolder(itemId: orgItem.id, folderId: "work")

        let item = try await cached()
        XCTAssertEqual(item, orgItem.with(folderId: "work"))
        XCTAssertEqual(item.revisionDate, revision, "The servers do not bump the cipher's revision on /partial")
    }

    func testMoveItemsToFolder_keepsEveryOtherField() async throws {
        try await sut.moveItemsToFolder(itemIds: [orgItem.id], folderId: "work")

        let item = try await cached()
        XCTAssertEqual(item, orgItem.with(folderId: "work"))
        XCTAssertEqual(mockAPI.moveCalls.first?.ids, [orgItem.id])
    }

    func testDeleteFolder_unfoldersItemAndKeepsEveryOtherField() async throws {
        try await sut.deleteFolder(id: "old-folder")

        let item = try await cached()
        XCTAssertEqual(item, orgItem.with(folderId: nil))
    }

    // MARK: - 1.4 Move, then edit: the save is still an org save

    func testMoveThenUpdate_encryptsWithTheOrgKey() async throws {
        await mockCrypto.unlockWith(keys: vaultKeys)
        mockCrypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        await orgKeyCache.store(key: orgKeys, for: "org-1")
        // The full save below is built over the server's stored record of the item.
        try await RepositoryFixtures.seedRecords(
            for: [orgItem], in: recordStore, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys])
        try await sut.moveItemToFolder(itemId: orgItem.id, folderId: "work")

        var draft = DraftVaultItem(try await cached())
        draft.name = "Renamed"
        _ = try await sut.update(draft)

        let sent = try XCTUnwrap(mockAPI.lastUpdatedCipher)
        XCTAssertEqual(sent.organizationId, "org-1")
        let name = try EncString(string: sent.name)
        XCTAssertEqual(String(data: try name.decrypt(keys: orgKeys), encoding: .utf8), "Renamed",
                       "The item must be encrypted with the organization key")
        XCTAssertThrowsError(try name.decrypt(keys: vaultKeys), "Not with the personal vault key")
    }

    // MARK: - Move, then edit: single and bulk moves, org key and collections stay intact

    /// What the stored server record holds for `orgItem` before any move: a move changes the cache
    /// (and the server's per-user folder) but never this record, so a save built over it must take the
    /// folder from the draft and the organization key and collections from the item.
    private func prepareFullSaves() async throws {
        await mockCrypto.unlockWith(keys: vaultKeys)
        mockCrypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        await orgKeyCache.store(key: orgKeys, for: "org-1")
        try await RepositoryFixtures.seedRecords(
            for: [orgItem], in: recordStore, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys])
        let stored = await recordStore.record(for: orgItem.id)
        XCTAssertEqual(stored?.folderId, "old-folder", "the stored record holds the folder from before the move")
    }

    /// Renames the cached item (as the edit sheet would) and saves it.
    @discardableResult
    private func rename(to name: String) async throws -> RawCipher {
        var draft = DraftVaultItem(try await cached())
        draft.name = name
        _ = try await sut.update(draft)
        return try XCTUnwrap(mockAPI.lastUpdatedCipher)
    }

    private func assertOrgSave(
        _ sent: RawCipher, name: String, folderId: String?, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(sent.organizationId, "org-1", file: file, line: line)
        let encName = try EncString(string: sent.name)
        XCTAssertEqual(String(data: try encName.decrypt(keys: orgKeys), encoding: .utf8), name,
                       "encrypted with the organization key", file: file, line: line)
        XCTAssertThrowsError(try encName.decrypt(keys: vaultKeys), "not with the vault key", file: file, line: line)
        XCTAssertEqual(mockAPI.lastUpdatedCipherCollections?.id, orgItem.id, file: file, line: line)
        XCTAssertEqual(mockAPI.lastUpdatedCipherCollections?.collectionIds, ["col-a"],
                       "the original collections", file: file, line: line)
        XCTAssertEqual(sent.folderId, folderId, "the draft's folder, not the stored record's", file: file, line: line)
    }

    func testSingleMoveThenUpdate_sendsOriginalCollectionsAndTheDraftFolder() async throws {
        try await prepareFullSaves()
        try await sut.moveItemToFolder(itemId: orgItem.id, folderId: "work")

        let sent = try await rename(to: "Renamed")

        try assertOrgSave(sent, name: "Renamed", folderId: "work")
        XCTAssertEqual(mockAPI.partialUpdates.count, 1, "the move went through /partial")
    }

    func testBulkMoveThenUpdate_usesTheOrgKeyAndOriginalCollections() async throws {
        try await prepareFullSaves()
        try await sut.moveItemsToFolder(itemIds: [orgItem.id], folderId: "work")
        XCTAssertEqual(mockAPI.moveCalls.first?.ids, [orgItem.id], "the drag-and-drop path")

        let sent = try await rename(to: "Renamed")

        try assertOrgSave(sent, name: "Renamed", folderId: "work")
    }

    func testMoveOutOfEveryFolderThenUpdate_keepsOrganizationAndCollections() async throws {
        try await prepareFullSaves()
        try await sut.moveItemsToFolder(itemIds: [orgItem.id], folderId: nil)

        let sent = try await rename(to: "Renamed")

        try assertOrgSave(sent, name: "Renamed", folderId: nil)
        XCTAssertNil(try encodedFolderId(sent), "no folder on the wire")
    }

    func testSingleMoveOutOfEveryFolderThenUpdate_keepsOrganizationAndCollections() async throws {
        try await prepareFullSaves()
        try await sut.moveItemToFolder(itemId: orgItem.id, folderId: nil)

        let sent = try await rename(to: "Renamed")

        try assertOrgSave(sent, name: "Renamed", folderId: nil)
        XCTAssertNil(try encodedFolderId(sent), "no folder on the wire")
    }

    func testUpdateThenBulkMove_endsWithOrganizationCollectionsAndFolder() async throws {
        try await prepareFullSaves()
        let first = try await rename(to: "First")
        try assertOrgSave(first, name: "First", folderId: "old-folder")

        try await sut.moveItemsToFolder(itemIds: [orgItem.id], folderId: "work")
        let second = try await rename(to: "Second")

        try assertOrgSave(second, name: "Second", folderId: "work")
    }

    func testKeyedFixtureOrgLogin_bulkMoveThenUpdate_usesItsOwnKey() async throws {
        let golden = try await GoldenVault.load()
        let stored = golden.cipher(id: GoldenVault.orgLoginId)
        let mapper = CipherMapper()
        let item = try mapper.map(raw: stored, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys).item
        let originalCollections = item.collectionIds
        XCTAssertFalse(originalCollections.isEmpty)

        await mockCrypto.unlockWith(keys: golden.vaultKeys)
        mockCrypto.stubbedVaultKeys = golden.vaultKeys
        await orgKeyCache.replaceAll(with: golden.orgKeys)
        let token = await recordStore.currentGeneration()
        await recordStore.upsert(stored, ifCurrent: token)
        await sut.populate(items: [item], folders: [Folder(id: "work", name: "Work")], organizations: [],
                           collections: [], syncedAt: Date())
        try await sut.moveItemsToFolder(itemIds: [item.id], folderId: "work")

        var draft = DraftVaultItem(try await sut.itemDetail(id: item.id))
        draft.name = "Renamed org login"
        _ = try await sut.update(draft)

        let sent = try XCTUnwrap(mockAPI.lastUpdatedCipher)
        XCTAssertNotNil(stored.key)
        XCTAssertEqual(sent.key, stored.key, "the item key is sent as stored")
        XCTAssertEqual(sent.organizationId, GoldenVault.orgId)
        XCTAssertEqual(sent.folderId, "work")
        XCTAssertEqual(mockAPI.lastUpdatedCipherCollections?.collectionIds, originalCollections)
        let orgKey = try XCTUnwrap(golden.orgKeys[GoldenVault.orgId])
        let itemKeys = try mapper.effectiveKeys(for: stored, activeKeys: orgKey)
        let encName = try EncString(string: sent.name)
        XCTAssertEqual(String(data: try encName.decrypt(keys: itemKeys), encoding: .utf8), "Renamed org login")
        XCTAssertThrowsError(try encName.decrypt(keys: orgKey), "not under the organization key")
        XCTAssertThrowsError(try encName.decrypt(keys: golden.vaultKeys), "not under the vault key")
    }

    /// `folderId` of the request as it is sent: nil when absent or null.
    private func encodedFolderId(_ cipher: RawCipher) throws -> String? {
        guard case .object(let members) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cipher)) else {
            throw CocoaError(.coderInvalidValue)
        }
        if case .string(let id)? = members["folderId"] { return id }
        return nil
    }

    // MARK: - 2.1 / 2.2 Favorite via /partial

    func testSetFavorite_sendsOnlyAPartialUpdate() async throws {
        let updated = try await sut.setFavorite(itemId: orgItem.id, isFavorite: true)

        XCTAssertEqual(mockAPI.partialUpdates.count, 1)
        XCTAssertEqual(mockAPI.partialUpdates.first?.id, orgItem.id)
        XCTAssertEqual(mockAPI.partialUpdates.first?.favorite, true)
        XCTAssertEqual(mockAPI.partialUpdates.first?.folderId, "old-folder", "The cached folder is sent along")
        XCTAssertEqual(mockAPI.updateCipherCallCount, 0, "No full cipher PUT")
        XCTAssertEqual(mockAPI.updateCipherCollectionsCallCount, 0, "No collections request")
        XCTAssertEqual(updated, orgItem.with(isFavorite: true))
    }

    func testSetFavorite_keepsEveryOtherFieldInTheCache() async throws {
        _ = try await sut.setFavorite(itemId: orgItem.id, isFavorite: true)

        let item = try await cached()
        XCTAssertEqual(item, orgItem.with(isFavorite: true))
        XCTAssertEqual(item.revisionDate, revision)
    }

    func testSetFavorite_failure_leavesTheCacheUnchanged() async throws {
        mockAPI.updateCipherPartialShouldThrow = APIError.httpError(statusCode: 400, body: "")

        do {
            _ = try await sut.setFavorite(itemId: orgItem.id, isFavorite: true)
            XCTFail("Expected the API error")
        } catch {}

        let item = try await cached()
        XCTAssertEqual(item, orgItem)
    }

    // MARK: - Review: what the server answers

    /// Bitwarden server's Entity Framework backends (MySQL, PostgreSQL, SQLite) answer 200 to
    /// /partial without saving (`Infrastructure.EntityFramework/Vault/Repositories/CipherRepository.cs`,
    /// `UpdatePartialAsync`): the response then shows the old state.
    func testSetFavorite_serverDidNotSave_throwsAndKeepsCache() async throws {
        mockAPI.partialUpdateResponse = PartialCipherResponse(favorite: false, folderId: .some("old-folder"))

        do {
            _ = try await sut.setFavorite(itemId: orgItem.id, isFavorite: true)
            XCTFail("Expected an error: the server did not save the change")
        } catch let error as VaultError {
            guard case .partialUpdateNotSaved = error else { return XCTFail("Unexpected \(error)") }
        }
        let item = try await cached()
        XCTAssertEqual(item, orgItem)
    }

    func testMoveItemToFolder_serverDidNotSave_throwsAndKeepsCache() async throws {
        mockAPI.partialUpdateResponse = PartialCipherResponse(favorite: false, folderId: .some("old-folder"))

        do {
            try await sut.moveItemToFolder(itemId: orgItem.id, folderId: "work")
            XCTFail("Expected an error: the server did not save the change")
        } catch let error as VaultError {
            guard case .partialUpdateNotSaved = error else { return XCTFail("Unexpected \(error)") }
        }
        let item = try await cached()
        XCTAssertEqual(item, orgItem)
    }

    func testSetFavorite_responseWithoutFields_isAccepted() async throws {
        mockAPI.partialUpdateResponse = PartialCipherResponse(favorite: nil, folderId: nil)

        let updated = try await sut.setFavorite(itemId: orgItem.id, isFavorite: true)

        XCTAssertEqual(updated, orgItem.with(isFavorite: true))
    }

    func testMoveItemToFolder_folderIdCaseDiffers_isAccepted() async throws {
        mockAPI.partialUpdateResponse = PartialCipherResponse(favorite: false, folderId: .some("WORK"))

        try await sut.moveItemToFolder(itemId: orgItem.id, folderId: "work")

        let item = try await cached()
        XCTAssertEqual(item.folderId, "work")
    }

    /// The cache gets exactly the pair that was sent: a move and a star in flight at the same time
    /// each send the other field from their own snapshot, and the server keeps the last request.
    func testSetFavorite_cachesTheSentFolderToo() async throws {
        let sut = self.sut!
        mockAPI.whilePartialUpdateInFlight = { [orgItem] in
            // Another request changed the folder in the cache meanwhile.
            await sut.populate(items: [orgItem.with(folderId: "work")], folders: [], organizations: [],
                               collections: [], syncedAt: Date())
        }

        _ = try await sut.setFavorite(itemId: orgItem.id, isFavorite: true)

        let item = try await cached()
        XCTAssertEqual(item.folderId, "old-folder", "The server now has the folder this request sent")
        XCTAssertTrue(item.isFavorite)
    }

    // MARK: - Review: reentrancy

    /// The repository is an actor and reentrant: a sync can replace the cache while the request
    /// is in flight. The move must update the moved item, not whatever sits at its old index.
    func testMoveItemToFolder_cacheReplacedInFlight_updatesTheRightItem() async throws {
        let other = VaultItem(id: "aaa-other", name: "AAA Other", isFavorite: false, isDeleted: false,
                              creationDate: Date(), revisionDate: revision,
                              content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
        let sut = self.sut!
        mockAPI.whilePartialUpdateInFlight = { [orgItem] in
            await sut.populate(items: [other, orgItem], folders: [], organizations: [], collections: [], syncedAt: Date())
        }

        try await sut.moveItemToFolder(itemId: orgItem.id, folderId: "work")

        let moved = try await cached()
        let untouched = try await sut.itemDetail(id: other.id)
        XCTAssertEqual(moved.folderId, "work")
        XCTAssertEqual(untouched, other)
    }

    func testSetFavorite_itemGoneAfterSuccess_returnsTheUpdatedItem() async throws {
        let sut = self.sut!
        mockAPI.whilePartialUpdateInFlight = { await sut.clearVault() }

        let updated = try await sut.setFavorite(itemId: orgItem.id, isFavorite: true)

        XCTAssertEqual(updated, orgItem.with(isFavorite: true), "The server saved it; a lock meanwhile is no error")
    }

    func testSetFavorite_itemWithoutFolder_sendsNilFolder() async throws {
        try await sut.moveItemToFolder(itemId: orgItem.id, folderId: nil)
        mockAPI.partialUpdates = []

        _ = try await sut.setFavorite(itemId: orgItem.id, isFavorite: true)

        XCTAssertEqual(mockAPI.partialUpdates.count, 1)
        XCTAssertNil(mockAPI.partialUpdates.first?.folderId ?? nil)
    }
}

/// The partial request body on the wire (task 2.1): `folderId` is JSON `null` when the item has no
/// folder, as both servers expect.
final class PartialUpdateRequestTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.responder = { _ in .status(200, body: Data("{}".utf8)) }
    }

    func testUpdateCipherPartial_decodesFavoriteAndFolder() async throws {
        // Vaultwarden 1.37.4 answers with the cipher (`put_cipher_partial`, `Cipher::to_json`).
        StubURLProtocol.responder = { _ in .status(200, body: Data(#"{"id":"c1","favorite":true,"folderId":null,"object":"cipherDetails"}"#.utf8)) }
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)

        let response = try await client.updateCipherPartial(id: "c1", folderId: nil, favorite: true)

        XCTAssertEqual(response.favorite, true)
        XCTAssertEqual(response.folderId, .some(nil), "Present and null: no folder")
    }

    func testUpdateCipherPartial_withoutFolder_sendsJSONNull() async throws {
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)

        _ = try await client.updateCipherPartial(id: "c1", folderId: nil, favorite: true)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url?.path, "/api/ciphers/c1/partial")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["favorite"] as? Bool, true)
        XCTAssertTrue(body.keys.contains("folderId"), "folderId must be present")
        XCTAssertTrue(body["folderId"] is NSNull, "folderId must be JSON null")
    }
}
