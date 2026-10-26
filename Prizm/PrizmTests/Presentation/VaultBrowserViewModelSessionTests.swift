import XCTest
@testable import Prizm

/// Unit tests for `VaultBrowserViewModel.clearSession()` (fix-ui-journey-findings): after a lock or
/// sign-out, the view model holds no decrypted vault data, and a vault read that was in flight
/// cannot bring it back.
@MainActor
final class VaultBrowserViewModelSessionTests: XCTestCase {

    private var vault: MockVaultRepository!
    private var search: GatedSearchUseCase!
    private var sut: VaultBrowserViewModel!

    private let secretItem = VaultItem(
        id: "secret-1", name: "Secret", isFavorite: false, isDeleted: false,
        creationDate: .now, revisionDate: .now,
        content: .login(LoginContent(username: "alice", password: "hunter2", uris: [], totp: nil,
                                     notes: nil, customFields: []))
    )

    override func setUp() async throws {
        try await super.setUp()
        vault = MockVaultRepository()
        await vault.populate(items: [secretItem], folders: [], organizations: [], collections: [], syncedAt: .now)
        search = GatedSearchUseCase(results: [secretItem])
        sut = makeVaultBrowserViewModel(vault: vault, search: search)
    }

    override func tearDown() async throws {
        search.releaseAll()
        try await super.tearDown()
    }

    private func waitUntil(timeout: Duration = .milliseconds(500), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testClearSession_dropsSelectionCreateSheetAndEditState() {
        sut.itemSelection = secretItem
        sut.createItemType = .login
        sut.handleEditSheetState(true)

        sut.clearSession()

        XCTAssertNil(sut.itemSelection)
        XCTAssertNil(sut.createItemType, "A create sheet must not reopen after unlocking")
        XCTAssertFalse(sut.editSheetOpen, "Item → Save must not stay enabled")
    }

    func testClearSession_discardsVaultReadInFlight() async throws {
        // `init` starts a refresh too; wait until both are held at the gate.
        sut.refreshItems()
        try await waitUntil { self.search.pendingCount >= 2 }

        sut.clearSession()
        search.releaseAll()
        // Give the released read time to deliver its result, if it still would.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(sut.displayedItems.isEmpty,
                      "A read started before the lock must not list decrypted items afterwards")
    }

    func testRefreshStartedAfterClearSession_isDiscarded() async throws {
        sut.clearSession()
        // The lock clears the vault store only after some awaits; a refresh started in between
        // (for example by resetting the search term) still finds decrypted items there.
        sut.refreshItems()
        try await waitUntil { self.search.pendingCount >= 2 }
        search.releaseAll()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(sut.displayedItems.isEmpty, "Nothing may be listed until a new session begins")
    }

    func testSaveHandler_afterClearSession_isIgnored() {
        // A save or favorite toggle that was in flight during the lock completes afterwards.
        let onSaved = sut.saveHandler()
        sut.clearSession()

        onSaved(secretItem)

        XCTAssertNil(sut.itemSelection, "A late save must not select the decrypted item again")
    }

    func testSaveHandler_inNextSession_isIgnored() {
        // A slow save can complete after the vault was unlocked again, or another account signed in.
        let onSaved = sut.saveHandler()
        sut.clearSession()
        sut.beginSession()

        onSaved(secretItem)

        XCTAssertNil(sut.itemSelection, "A save from an earlier session must not select its item")
    }

    func testSaveHandler_inSameSession_selectsSavedItem() {
        let onSaved = sut.saveHandler()

        onSaved(secretItem)

        XCTAssertEqual(sut.itemSelection?.id, secretItem.id)
    }

    func testRefreshAfterBeginSession_listsItemsAgain() async throws {
        sut.clearSession()
        sut.beginSession()
        sut.refreshItems()
        // `init` starts a refresh too, so release every read until the new one has delivered.
        try await waitUntil {
            self.search.releaseAll()
            return !self.sut.displayedItems.isEmpty
        }

        XCTAssertEqual(sut.displayedItems.map(\.id), [secretItem.id], "The next session must work normally")
    }
}

/// The "+" menu and ⌘N are not offered in Trash (spec list-column-header); the view model refuses
/// a create sheet there as well.
@MainActor
final class VaultBrowserViewModelTrashTests: XCTestCase {

    func testCreateItemType_staysNilInTrash() async throws {
        let vault = MockVaultRepository()
        let sut = makeVaultBrowserViewModel(vault: vault, search: SearchVaultUseCaseImpl(vault: vault))
        sut.sidebarSelection = .trash

        sut.createItemType = .login

        XCTAssertNil(sut.createItemType)
    }

    func testCreateItemType_isSetOutsideTrash() async throws {
        let vault = MockVaultRepository()
        let sut = makeVaultBrowserViewModel(vault: vault, search: SearchVaultUseCaseImpl(vault: vault))
        sut.sidebarSelection = .type(.login)

        sut.createItemType = .login

        XCTAssertEqual(sut.createItemType, .login)
    }
}

@MainActor
private func makeVaultBrowserViewModel(vault: MockVaultRepository, search: any SearchVaultUseCase) -> VaultBrowserViewModel {
    let syncRepo = MockSyncTimestampRepository(storedDate: nil)
    return VaultBrowserViewModel(
        vault:           vault,
        search:          search,
        delete:          StubDeleteUseCase(),
        permanentDelete: StubPermanentDeleteUseCase(),
        restore:         StubRestoreUseCase(),
        createFolder:     StubCreateFolder(),
        renameFolder:     StubRenameFolder(),
        deleteFolder:     StubDeleteFolder(),
        moveItem:         StubMoveItem(),
        createCollection: StubCreateCollection(),
        renameCollection: StubRenameCollection(),
        deleteCollection: StubDeleteCollection(),
        syncTimestamp:    syncRepo,
        getLastSyncDate:  GetLastSyncDateUseCaseImpl(repository: syncRepo)
    )
}

/// A search that suspends until the test releases it, to hold a vault read in flight.
@MainActor
private final class GatedSearchUseCase: SearchVaultUseCase {
    private let results: [VaultItem]
    private var pending: [CheckedContinuation<Void, Never>] = []
    var pendingCount: Int { pending.count }

    init(results: [VaultItem]) { self.results = results }

    func execute(query: String, in selection: SidebarSelection) async throws -> [VaultItem] {
        await withCheckedContinuation { pending.append($0) }
        return results
    }

    func releaseAll() {
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume() }
    }
}

// MARK: - Stub use cases (minimal, no-op)

private final class StubDeleteUseCase: DeleteVaultItemUseCase {
    func execute(id: String) async throws {}
}

private final class StubPermanentDeleteUseCase: PermanentDeleteVaultItemUseCase {
    func execute(id: String) async throws {}
}

private final class StubRestoreUseCase: RestoreVaultItemUseCase {
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
