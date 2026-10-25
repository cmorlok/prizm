import XCTest
@testable import Prizm

/// Empty Trash deletes exactly the trashed items, never via the purge endpoint, on fresh data, and
/// reports the outcome (openspec change fix-empty-trash).
final class EmptyTrashRequestTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.responder = { _ in .status(200) }
    }

    // MARK: - 2.2 The bulk request

    func testPermanentDeleteCiphers_sendsDeleteWithIds() async throws {
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        await client.setAccessToken("token-1")

        try await client.permanentDeleteCiphers(ids: ["a", "b"])

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/ciphers")
        XCTAssertEqual(request.jsonBody?["ids"] as? [String], ["a", "b"])
        XCTAssertEqual(request.headers["Authorization"], "Bearer token-1")
    }

    // MARK: - 2.1 Purge guard: source scan

    /// `POST /ciphers/purge` deletes every item the user owns (and on Vaultwarden every folder).
    /// No app source may name it, except in a comment that warns against it.
    func testAppSources_neverNameThePurgeEndpoint() throws {
        // …/Prizm/PrizmTests/Data/EmptyTrashTests.swift → …/Prizm
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.path
            if path.contains("/PrizmTests/") || path.contains("/UITests/") { continue }
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains("ciphers/purge") {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "The scan must have found the app sources")
        XCTAssertEqual(offenders, [], "ciphers/purge outside a comment")
    }
}

@MainActor
final class EmptyTrashRepositoryTests: XCTestCase {

    private func item(_ id: String, deleted: Bool) -> VaultItem {
        VaultItem(id: id, name: id, isFavorite: false, isDeleted: deleted, creationDate: Date(), revisionDate: Date(),
                  content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
    }

    // MARK: - 3.1 Only trashed ids, in chunks of 500

    func testPermanentDeleteItems_sendsOnlyTrashedIdsInChunksOf500() async throws {
        let api = MockPrizmAPIClient()
        let sut = VaultRepositoryImpl(apiClient: api, crypto: MockPrizmCryptoService())
        let trashed = (0..<1_200).map { item("t\($0)", deleted: true) }
        let active = (0..<10).map { item("a\($0)", deleted: false) }
        await sut.populate(items: trashed + active, folders: [], organizations: [], collections: [], syncedAt: Date())

        // An active id slipped into the list must never be sent.
        try await sut.permanentDeleteItems(ids: trashed.map(\.id) + ["a0"])

        XCTAssertEqual(api.bulkDeleteCalls.map(\.count), [500, 500, 200])
        let sent = Set(api.bulkDeleteCalls.flatMap { $0 })
        XCTAssertEqual(sent, Set(trashed.map(\.id)))
        let remaining = try await sut.items(for: .allItems).map(\.id)
        XCTAssertEqual(Set(remaining), Set(active.map(\.id)), "Active items stay; deleted ones leave the cache")
    }

    func testPermanentDeleteItems_failingChunk_othersStillGoThrough() async throws {
        let api = MockPrizmAPIClient()
        api.bulkDeleteFailsOnCall = 1
        let sut = VaultRepositoryImpl(apiClient: api, crypto: MockPrizmCryptoService())
        let trashed = (0..<1_200).map { item("t\($0)", deleted: true) }
        await sut.populate(items: trashed, folders: [], organizations: [], collections: [], syncedAt: Date())

        do {
            try await sut.permanentDeleteItems(ids: trashed.map(\.id))
            XCTFail("Expected the chunk's error")
        } catch let error as PermanentDeleteError {
            XCTAssertEqual(error.deleted, 700, "Chunks 1 and 3 went through")
        }

        XCTAssertEqual(api.bulkDeleteCalls.count, 3, "A failing chunk does not stop the others")
        let left = try await sut.items(for: .trash)
        XCTAssertEqual(left.count, 500, "Only the failing chunk's items remain")
    }
}

@MainActor
final class EmptyTrashUseCaseTests: XCTestCase {

    private var vault: MockVaultRepository!
    private var sync: MockSyncUseCase!
    private var sut: EmptyTrashUseCaseImpl!

    private func item(_ id: String, deleted: Bool) -> VaultItem {
        VaultItem(id: id, name: id, isFavorite: false, isDeleted: deleted, creationDate: Date(), revisionDate: Date(),
                  content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
    }

    override func setUp() async throws {
        try await super.setUp()
        vault = MockVaultRepository()
        sync = MockSyncUseCase()
        sut = EmptyTrashUseCaseImpl(repository: vault, sync: sync)
    }

    // MARK: - D2 Fresh data before confirming

    func testPrepare_syncsFirstAndReturnsTheFreshTrash() async throws {
        await vault.populate(items: [item("x", deleted: true), item("y", deleted: true)], folders: [],
                             organizations: [], collections: [], syncedAt: Date())
        // X was restored on another device: the sync brings it back as active.
        sync.onExecute = { [vault, item] in
            await vault!.populate(items: [item("x", false), item("y", true)], folders: [],
                                  organizations: [], collections: [], syncedAt: Date())
        }

        let ids = try await sut.prepare()

        XCTAssertEqual(sync.executeCount, 1)
        XCTAssertEqual(ids, ["y"])
    }

    func testPrepare_syncFails_throwsTheRefreshError() async throws {
        sync.executeError = URLError(.notConnectedToInternet)

        do {
            _ = try await sut.prepare()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Couldn't refresh the trash. Try again.")
        }
    }

    // MARK: - 3.2 / D4 Sync after deleting, report what remains

    func testExecute_deletesThenSyncsAndReportsRemaining() async throws {
        await vault.populate(items: [item("p1", deleted: true), item("p2", deleted: true), item("org", deleted: true)],
                             folders: [], organizations: [], collections: [], syncedAt: Date())
        // The server kept the org item the user may not delete.
        sync.onExecute = { [vault, item] in
            await vault!.populate(items: [item("org", true)], folders: [], organizations: [], collections: [], syncedAt: Date())
        }

        let result = try await sut.execute(ids: ["p1", "p2", "org"])

        XCTAssertEqual(vault.permanentDeleteItemsCalls, [["p1", "p2", "org"]])
        XCTAssertEqual(sync.executeCount, 1, "A sync runs after the delete")
        // The server answered 200 for all three, but the sync shows the org item is still there.
        XCTAssertEqual(result, EmptyTrashResult(requested: 3, deleted: 2, remaining: 1, failure: nil, synced: true))
    }

    func testExecute_followUpSyncFails_isReported() async throws {
        await vault.populate(items: [item("p1", deleted: true)], folders: [], organizations: [], collections: [], syncedAt: Date())
        sync.executeError = URLError(.timedOut)  // `execute` syncs only once, after the delete

        let result = try await sut.execute(ids: ["p1"])

        XCTAssertFalse(result.synced, "A failed follow-up sync must not be recorded as a sync")
        XCTAssertEqual(result.remaining, 0, "From the cache, which already dropped the deleted item")
        XCTAssertEqual(result.deleted, 1, "Without a sync, the count the delete calls reported")
    }

    func testExecute_connectionFailure_isReportedAsConnection() async throws {
        await vault.populate(items: [item("p1", deleted: true)], folders: [], organizations: [], collections: [], syncedAt: Date())
        vault.stubbedPermanentDeleteItemsError = PermanentDeleteError(deleted: 0, underlying: URLError(.notConnectedToInternet))

        let result = try await sut.execute(ids: ["p1"])

        XCTAssertEqual(result.failure, .connection)
    }

    func testExecute_deleteFails_stillSyncsAndReports() async throws {
        await vault.populate(items: [item("p1", deleted: true), item("p2", deleted: true)],
                             folders: [], organizations: [], collections: [], syncedAt: Date())
        vault.stubbedPermanentDeleteItemsError = APIError.httpError(statusCode: 400, body: "")
        sync.onExecute = { [vault, item] in
            await vault!.populate(items: [item("p2", true)], folders: [], organizations: [], collections: [], syncedAt: Date())
        }

        let result = try await sut.execute(ids: ["p1", "p2"])

        XCTAssertEqual(sync.executeCount, 1)
        // The chunk failed, but the sync shows p1 is gone: it counts as deleted.
        XCTAssertEqual(result, EmptyTrashResult(requested: 2, deleted: 1, remaining: 1, failure: .refused, synced: true))
    }
}

@MainActor
final class EmptyTrashViewModelTests: XCTestCase {

    private final class StubEmptyTrash: EmptyTrashUseCase {
        var prepared: Result<[String], Error> = .success([])
        var result = EmptyTrashResult(requested: 0, deleted: 0, remaining: 0, failure: nil, synced: true)
        private(set) var executedIds: [[String]] = []

        func prepare() async throws -> [String] { try prepared.get() }
        func execute(ids: [String]) async throws -> EmptyTrashResult {
            executedIds.append(ids)
            return result
        }
    }

    private var stub: StubEmptyTrash!
    private var sut: VaultBrowserViewModel!

    override func setUp() async throws {
        try await super.setUp()
        stub = StubEmptyTrash()
        sut = makeEmptyTrashTestViewModel(emptyTrash: stub)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(500)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - 4.1 Refresh, then confirm with the fresh count

    func testBegin_refreshesThenAsksWithTheFreshCount() async throws {
        stub.prepared = .success(["y"])

        sut.beginEmptyTrash()
        try await waitUntil { self.sut.emptyTrashConfirmation != nil }

        XCTAssertEqual(sut.emptyTrashConfirmation?.title, "Permanently delete 1 item?")
        XCTAssertEqual(sut.emptyTrashConfirmation?.message, "This can't be undone.")
        XCTAssertEqual(stub.executedIds, [], "Nothing is deleted before the user confirms")
    }

    func testBegin_refreshFails_showsMessageAndDeletesNothing() async throws {
        stub.prepared = .failure(EmptyTrashError.refreshFailed)

        sut.beginEmptyTrash()
        try await waitUntil { self.sut.actionError != nil }

        XCTAssertEqual(sut.actionError, "Couldn't refresh the trash. Try again.")
        XCTAssertNil(sut.emptyTrashConfirmation)
        XCTAssertEqual(stub.executedIds, [])
    }

    func testConfirm_deletesTheConfirmedIdsAndAnnounces() async throws {
        stub.prepared = .success(["a", "b"])
        stub.result = EmptyTrashResult(requested: 2, deleted: 2, remaining: 0, failure: nil, synced: true)
        sut.beginEmptyTrash()
        try await waitUntil { self.sut.emptyTrashConfirmation != nil }
        XCTAssertEqual(sut.emptyTrashConfirmation?.title, "Permanently delete 2 items?")

        sut.confirmEmptyTrash(try XCTUnwrap(sut.emptyTrashConfirmation))
        try await waitUntil { self.sut.announcement != nil }

        XCTAssertEqual(stub.executedIds, [["a", "b"]])
        XCTAssertEqual(sut.announcement, "2 items permanently deleted")
        XCTAssertNil(sut.actionError)
    }

    // MARK: - 5.1 Partial failure

    func testConfirm_itemsRemain_showsTheCount() async throws {
        for (remaining, expected) in [(1, "1 item could not be deleted. You may not have permission to delete them."),
                                      (2, "2 items could not be deleted. You may not have permission to delete them.")] {
            sut.actionError = nil
            stub.prepared = .success(["a", "b", "c"])
            stub.result = EmptyTrashResult(requested: 3, deleted: 3 - remaining, remaining: remaining, failure: .refused, synced: true)
            sut.beginEmptyTrash()
            try await waitUntil { self.sut.emptyTrashConfirmation != nil }

            sut.confirmEmptyTrash(try XCTUnwrap(sut.emptyTrashConfirmation))
            try await waitUntil { self.sut.actionError != nil }

            XCTAssertEqual(sut.actionError, expected)
        }
    }

    func testConfirm_connectionFailure_saysSo() async throws {
        stub.prepared = .success(["a"])
        stub.result = EmptyTrashResult(requested: 1, deleted: 0, remaining: 1, failure: .connection, synced: false)
        sut.beginEmptyTrash()
        try await waitUntil { self.sut.emptyTrashConfirmation != nil }

        sut.confirmEmptyTrash(try XCTUnwrap(sut.emptyTrashConfirmation))
        try await waitUntil { self.sut.actionError != nil }

        XCTAssertEqual(sut.actionError, "1 item could not be deleted. Check your connection and try again.")
        XCTAssertNil(sut.announcement, "Nothing deleted: only the alert reports it")
    }

    /// The alert can close (and cancel) before its button's action runs; the action still works.
    func testConfirm_afterTheAlertCancelled_stillDeletes() async throws {
        stub.prepared = .success(["a"])
        stub.result = EmptyTrashResult(requested: 1, deleted: 1, remaining: 0, failure: nil, synced: true)
        sut.beginEmptyTrash()
        try await waitUntil { self.sut.emptyTrashConfirmation != nil }
        let confirmation = try XCTUnwrap(sut.emptyTrashConfirmation)

        sut.cancelEmptyTrash()
        sut.confirmEmptyTrash(confirmation)
        try await waitUntil { self.sut.announcement != nil }

        XCTAssertEqual(stub.executedIds, [["a"]])
    }

    func testLock_resetsTheEmptyTrashState() async throws {
        stub.prepared = .success(["a"])
        sut.beginEmptyTrash()
        try await waitUntil { self.sut.emptyTrashConfirmation != nil }

        sut.clearSession()

        XCTAssertNil(sut.emptyTrashConfirmation, "No confirmation may come back after unlock")
        XCTAssertFalse(sut.isEmptyingTrash, "The button must not stay disabled")
    }

    func testCancel_deletesNothing() async throws {
        stub.prepared = .success(["a"])
        sut.beginEmptyTrash()
        try await waitUntil { self.sut.emptyTrashConfirmation != nil }

        sut.cancelEmptyTrash()

        XCTAssertNil(sut.emptyTrashConfirmation)
        XCTAssertEqual(stub.executedIds, [])
    }
}

@MainActor
private func makeEmptyTrashTestViewModel(emptyTrash: any EmptyTrashUseCase,
                                         vault: MockVaultRepository = MockVaultRepository()) -> VaultBrowserViewModel {
    let syncRepo = MockSyncTimestampRepository(storedDate: nil)
    return VaultBrowserViewModel(
        vault:           vault,
        search:          SearchVaultUseCaseImpl(vault: vault),
        delete:          DeleteVaultItemUseCaseImpl(repository: vault),
        permanentDelete: PermanentDeleteVaultItemUseCaseImpl(repository: vault),
        restore:         RestoreVaultItemUseCaseImpl(repository: vault),
        createFolder:     CreateFolderUseCaseImpl(repository: vault),
        renameFolder:     RenameFolderUseCaseImpl(repository: vault),
        deleteFolder:     DeleteFolderUseCaseImpl(repository: vault),
        moveItem:         MoveItemToFolderUseCaseImpl(repository: vault),
        setFavorite:      SetFavoriteUseCaseImpl(repository: vault),
        emptyTrash:       emptyTrash,
        createCollection: CreateCollectionUseCaseImpl(repository: vault),
        renameCollection: RenameCollectionUseCaseImpl(repository: vault),
        deleteCollection: DeleteCollectionUseCaseImpl(repository: vault),
        syncTimestamp:    syncRepo,
        getLastSyncDate:  GetLastSyncDateUseCaseImpl(repository: syncRepo)
    )
}

/// A sync that finishes after a lock must not put decrypted data back (fix-empty-trash review).
@MainActor
final class SyncAfterLockTests: XCTestCase {

    func testSync_vaultLockedWhileFetching_writesNothing() async throws {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        let vault = MockVaultRepository()
        await crypto.unlockWith(keys: CryptoKeys(encryptionKey: Data(count: 32), macKey: Data(count: 32)))
        crypto.stubbedDecryptList = [VaultItem(id: "x", name: "Secret", isFavorite: false, isDeleted: false,
                                               creationDate: Date(), revisionDate: Date(),
                                               content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))]
        api.syncResponse = SyncResponse(
            profile: RawProfile(id: "pid", email: "a@example.com", name: nil, key: "2.k==", privateKey: nil),
            ciphers: [], folders: [], organizations: [], collections: []
        )
        api.whileFetchingSync = { await crypto.lockVault() }
        let sync = SyncRepositoryImpl(apiClient: api, crypto: crypto, vaultRepository: vault,
                                      vaultKeyCache: VaultKeyCache(), orgKeyCache: OrgKeyCache())

        do {
            _ = try await sync.sync(progress: { _ in })
            XCTFail("Expected the sync to stop")
        } catch {}

        XCTAssertTrue(vault.populatedItems.isEmpty, "No decrypted item may reach the store after a lock")
    }
}

/// The button is offered only while Trash has items (spec scenario "Button state").
@MainActor
final class EmptyTrashButtonStateTests: XCTestCase {

    private struct UnusedEmptyTrash: EmptyTrashUseCase {
        func prepare() async throws -> [String] { [] }
        func execute(ids: [String]) async throws -> EmptyTrashResult {
            EmptyTrashResult(requested: 0, deleted: 0, remaining: 0, failure: nil, synced: true)
        }
    }

    func testEmptyTrash_isOfferedOnlyWhileTrashHasItems() async throws {
        let vault = MockVaultRepository()
        let sut = makeEmptyTrashTestViewModel(emptyTrash: UnusedEmptyTrash(), vault: vault)
        XCTAssertFalse(sut.canEmptyTrash, "No counts yet: Trash counts as empty")

        vault.stubbedItemCounts = [.trash: 2]
        sut.refreshCounts()
        let deadline = ContinuousClock.now + .seconds(2)
        while !sut.canEmptyTrash, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(sut.canEmptyTrash)

        vault.stubbedItemCounts = [.trash: 0]
        sut.refreshCounts()
        while sut.canEmptyTrash, ContinuousClock.now < deadline + .seconds(2) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(sut.canEmptyTrash)
    }
}

