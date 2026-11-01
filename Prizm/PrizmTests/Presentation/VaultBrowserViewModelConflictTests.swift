import XCTest
@testable import Prizm

/// Unit tests for the two services the edit sheet uses after a stale-write conflict:
/// `resyncAfterConflict()` and `latestItem(id:)`.
@MainActor
final class VaultBrowserViewModelConflictTests: XCTestCase {

    private var vault: MockVaultRepository!
    private var sync:  MockSyncUseCase!
    private var sut:   VaultBrowserViewModel!

    private func item(id: String = "item-1", name: String = "Old", isDeleted: Bool = false,
                      editBlock: EditBlockReason? = nil) -> VaultItem {
        VaultItem(
            id: id, name: name, isFavorite: false, isDeleted: isDeleted,
            creationDate: .now, revisionDate: .now,
            content: .login(LoginContent(username: "alice", password: "hunter2", uris: [], totp: nil,
                                         notes: nil, customFields: [])),
            editBlock: editBlock
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        vault = MockVaultRepository()
        sync  = MockSyncUseCase()
        sut   = makeViewModel()
    }

    private func makeViewModel() -> VaultBrowserViewModel {
        let syncRepo = MockSyncTimestampRepository(storedDate: nil)
        return VaultBrowserViewModel(
            vault:            vault,
            search:           SearchVaultUseCaseImpl(vault: vault),
            delete:           StubConflictDelete(),
            permanentDelete:  StubConflictPermanentDelete(),
            restore:          StubConflictRestore(),
            createFolder:     StubCreateFolder(),
            renameFolder:     StubRenameFolder(),
            deleteFolder:     StubDeleteFolder(),
            moveItem:         StubMoveItem(),
            setFavorite:      SetFavoriteUseCaseImpl(repository: vault),
            emptyTrash:       EmptyTrashUseCaseImpl(repository: vault, sync: MockSyncUseCase()),
            clipboard:        ClipboardServiceImpl(pasteboard: FakePasteboard()),
            createCollection: StubCreateCollection(),
            renameCollection: StubRenameCollection(),
            deleteCollection: StubDeleteCollection(),
            syncTimestamp:    syncRepo,
            getLastSyncDate:  GetLastSyncDateUseCaseImpl(repository: syncRepo),
            sync:             sync,
            conflictResyncRetryDelay: .zero
        )
    }

    // MARK: - resyncAfterConflict

    func testResync_success_reportsSyncedAndRefreshes() async {
        let syncedAt = Date(timeIntervalSince1970: 2_000_000)
        sync.stubbedResult = SyncResult(syncedAt: syncedAt, totalCiphers: 0, failedDecryptionCount: 0)

        let outcome = await sut.resyncAfterConflict()

        XCTAssertEqual(outcome, .synced)
        XCTAssertEqual(sync.executeCount, 1)
        XCTAssertEqual(sut.lastSyncedAt, syncedAt)
        XCTAssertNil(sut.syncErrorMessage)
    }

    func testResync_failure_reportsTheSyncError() async {
        sync.executeError = SyncError.networkUnavailable
        let message = SyncError.networkUnavailable.localizedDescription

        let outcome = await sut.resyncAfterConflict()

        XCTAssertEqual(outcome, .failed(message))
        XCTAssertEqual(sut.syncErrorMessage, message)
    }

    func testResync_lockDuringSync_dropsTheResult() async {
        let before = sut.lastSyncedAt
        sync.onExecute = { [sut] in sut?.clearSession() }

        let outcome = await sut.resyncAfterConflict()

        guard case .failed = outcome else { return XCTFail("A sync discarded by a lock must not report .synced: \(outcome)") }
        XCTAssertEqual(sut.lastSyncedAt, before, "A result that arrives after the lock must not be applied")
        XCTAssertNil(sut.syncErrorMessage)
    }

    func testResync_syncInProgress_retriesUntilItsOwnSyncRan() async {
        sync.executeErrors = [SyncError.syncInProgress, SyncError.syncInProgress, nil]

        let outcome = await sut.resyncAfterConflict()

        XCTAssertEqual(outcome, .synced)
        XCTAssertEqual(sync.executeCount, 3, "Only the third call ran its own sync; the first two met the running one")
    }

    func testResync_syncInProgressTwentyTimes_fails() async {
        sync.executeErrors = Array(repeating: SyncError.syncInProgress, count: 20)

        let outcome = await sut.resyncAfterConflict()

        XCTAssertEqual(outcome, .failed("Sync is already in progress."))
        XCTAssertEqual(sync.executeCount, 20)
    }

    func testResyncFailure_isNotAnnouncedByTheBrowser() async {
        XCTAssertFalse(sut.syncErrorFromConflictResync)

        sync.executeError = SyncError.networkUnavailable
        _ = await sut.resyncAfterConflict()
        XCTAssertTrue(sut.syncErrorFromConflictResync)
        XCTAssertEqual(sut.syncErrorMessage, SyncError.networkUnavailable.localizedDescription)

        sync.executeError = nil
        _ = await sut.resyncAfterConflict()
        XCTAssertFalse(sut.syncErrorFromConflictResync, "A successful sync clears the flag")

        sync.executeError = SyncError.networkUnavailable
        _ = await sut.resyncAfterConflict()
        sut.dismissSyncError()
        XCTAssertFalse(sut.syncErrorFromConflictResync, "Dismissing the banner clears the flag")

        _ = await sut.resyncAfterConflict()
        sut.handleSyncError("Some other failure")
        XCTAssertFalse(sut.syncErrorFromConflictResync, "An error from anywhere else is announced as usual")

        _ = await sut.resyncAfterConflict()
        XCTAssertTrue(sut.syncErrorFromConflictResync)
        sut.clearSession()
        XCTAssertFalse(sut.syncErrorFromConflictResync, "A lock clears the flag")
    }

    // MARK: - Selection after the resync

    private func waitUntil(timeout: Duration = .milliseconds(500), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testResync_movesTheSelectionToTheSyncedItem() async throws {
        sut.itemSelection = item(name: "Old")
        let synced = item(name: "New")
        sync.onExecute = { [vault] in
            await vault?.populate(items: [synced], folders: [], organizations: [], collections: [], syncedAt: .now)
        }

        let outcome = await sut.resyncAfterConflict()
        try await waitUntil { sut.itemSelection?.name == "New" }

        XCTAssertEqual(outcome, .synced)
        XCTAssertEqual(sut.itemSelection?.id, "item-1")
        XCTAssertEqual(sut.itemSelection?.name, "New", "The detail pane follows the synced copy of the same item")
    }

    func testResync_itemGone_neverSelectsAnotherItem() async throws {
        sut.itemSelection = item()
        let other = item(id: "other", name: "Other")
        sync.onExecute = { [vault] in
            await vault?.populate(items: [other], folders: [], organizations: [], collections: [], syncedAt: .now)
        }

        let outcome = await sut.resyncAfterConflict()
        // Wait until the list shows the synced vault and the selection refresh has read it: that
        // refresh is where a wrong selection would come from.
        try await waitUntil { vault.itemDetailCallCount > 0 && sut.displayedItems.map(\.id) == ["other"] }
        // The refresh assigns right after its read; let that step run before looking.
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(outcome, .synced)
        XCTAssertGreaterThan(vault.itemDetailCallCount, 0, "The selection refresh ran")
        XCTAssertEqual(sut.displayedItems.map(\.id), ["other"])
        XCTAssertEqual(sut.itemSelection?.id, "item-1",
                       "The selection stays on the edited item, whose sheet explains that it is gone; it never moves to another item")
    }

    // MARK: - latestItem

    func testLatestItem_findsTheSyncedItem() async {
        await vault.populate(items: [item(name: "New")], folders: [], organizations: [], collections: [], syncedAt: .now)

        let latest = await sut.latestItem(id: "item-1")

        guard case .available(let found) = latest else { return XCTFail("Expected .available, got \(latest)") }
        XCTAssertEqual(found.name, "New")
    }

    func testLatestItem_trashedOrMissing_isGone() async {
        await vault.populate(items: [item(id: "trashed", isDeleted: true)], folders: [], organizations: [],
                             collections: [], syncedAt: .now)

        let trashed = await sut.latestItem(id: "trashed")
        let missing = await sut.latestItem(id: "never-existed")

        XCTAssertEqual(trashed, .gone, "A trashed item cannot be edited")
        XCTAssertEqual(missing, .gone)
    }

    func testLatestItem_blockedItem_isAvailable() async {
        await vault.populate(items: [item(editBlock: .unsupportedFormat)], folders: [], organizations: [],
                             collections: [], syncedAt: .now)

        let latest = await sut.latestItem(id: "item-1")

        guard case .available(let found) = latest else { return XCTFail("Expected .available, got \(latest)") }
        XCTAssertEqual(found.editBlock, .unsupportedFormat)
    }
}

// MARK: - Stubs

private final class StubConflictDelete: DeleteVaultItemUseCase {
    func execute(id: String) async throws {}
}
private final class StubConflictPermanentDelete: PermanentDeleteVaultItemUseCase {
    func execute(id: String) async throws {}
}
private final class StubConflictRestore: RestoreVaultItemUseCase {
    func execute(id: String) async throws {}
}
private struct StubCreateFolder: CreateFolderUseCase {
    func execute(name: String) async throws -> Folder { Folder(id: "stub", name: name) }
}
private struct StubRenameFolder: RenameFolderUseCase {
    func execute(id: String, name: String) async throws -> Folder { Folder(id: id, name: name) }
}
private struct StubDeleteFolder: DeleteFolderUseCase {
    func execute(id: String) async throws {}
}
private struct StubMoveItem: MoveItemToFolderUseCase {
    func execute(itemId: String, folderId: String?) async throws {}
    func execute(itemIds: [String], folderId: String?) async throws {}
}
private struct StubCreateCollection: CreateCollectionUseCase {
    func execute(name: String, organizationId: String) async throws -> OrgCollection {
        OrgCollection(id: "stub", organizationId: organizationId, name: name)
    }
}
private struct StubRenameCollection: RenameCollectionUseCase {
    func execute(collectionId: String, name: String, organizationId: String) async throws -> OrgCollection {
        OrgCollection(id: collectionId, organizationId: organizationId, name: name)
    }
}
private struct StubDeleteCollection: DeleteCollectionUseCase {
    func execute(collectionId: String, organizationId: String) async throws {}
}
