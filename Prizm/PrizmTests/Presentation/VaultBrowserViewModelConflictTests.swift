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
            sync:             sync
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

    // MARK: - latestItem

    func testLatestItem_findsTheSyncedItem() async {
        await vault.populate(items: [item(name: "New")], folders: [], organizations: [], collections: [], syncedAt: .now)

        let latest = await sut.latestItem(id: "item-1")

        guard case .available(let found) = latest else { return XCTFail("Expected .available, got \(latest)") }
        XCTAssertEqual(found.name, "New")
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
