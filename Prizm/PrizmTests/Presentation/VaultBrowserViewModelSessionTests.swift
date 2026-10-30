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

    func testTriggerEdit_ignoresAnItemThatCannotBeEdited() {
        let blocked = VaultItem(
            id: "blocked-1", name: "Blocked", isFavorite: false, isDeleted: false,
            creationDate: .now, revisionDate: .now,
            content: .login(LoginContent(username: "bob", password: "pw", uris: [], totp: nil,
                                         notes: nil, customFields: [])),
            editBlock: .unsupportedFormat
        )
        let before = sut.editTrigger

        sut.itemSelection = blocked
        sut.triggerEdit()
        XCTAssertEqual(sut.editTrigger, before, "No trigger for a blocked item, from menu, toolbar or shortcut")

        sut.itemSelection = secretItem
        sut.triggerEdit()
        XCTAssertEqual(sut.editTrigger, before + 1, "A normal item still opens the edit sheet")
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

    func testCreateItemType_acceptsSSHKey() async throws {
        let vault = MockVaultRepository()
        let sut = makeVaultBrowserViewModel(vault: vault, search: SearchVaultUseCaseImpl(vault: vault))
        sut.sidebarSelection = .type(.sshKey)

        sut.createItemType = .sshKey

        XCTAssertEqual(sut.createItemType, .sshKey, "SSH keys can be created again (ssh-key-import-and-generation)")
    }
}

@MainActor
private func makeVaultBrowserViewModel(vault: MockVaultRepository, search: any SearchVaultUseCase,
                                       setArchived: (any SetItemArchivedUseCase)? = nil) -> VaultBrowserViewModel {
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
        setFavorite:      SetFavoriteUseCaseImpl(repository: vault),
        emptyTrash:       EmptyTrashUseCaseImpl(repository: vault, sync: MockSyncUseCase()),
        clipboard:        ClipboardServiceImpl(pasteboard: FakePasteboard()),
        createCollection: StubCreateCollection(),
        renameCollection: StubRenameCollection(),
        deleteCollection: StubDeleteCollection(),
        syncTimestamp:    syncRepo,
        getLastSyncDate:  GetLastSyncDateUseCaseImpl(repository: syncRepo),
        sync:             MockSyncUseCase(),
        setArchived:      setArchived
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

// MARK: - Archive (archived-items)

/// Archive actions in the browser (openspec change `archived-items`, tasks 3.3 and 4.3).
@MainActor
final class VaultBrowserViewModelArchiveTests: XCTestCase {

    private final class SpyArchiveUseCase: SetItemArchivedUseCase {
        var error: Error?
        var onExecute: ((String, Bool) async -> Void)?
        private(set) var calls: [(String, Bool)] = []
        func execute(id: String, archived: Bool) async throws {
            calls.append((id, archived))
            // While the request "runs", then its outcome.
            await onExecute?(id, archived)
            if let error { throw error }
        }
    }

    private var vault: MockVaultRepository!
    private var useCase: SpyArchiveUseCase!
    private var sut: VaultBrowserViewModel!

    private func item(_ id: String, archived: Bool = false, deleted: Bool = false) -> VaultItem {
        VaultItem(id: id, name: id, isFavorite: false, isDeleted: deleted, creationDate: Date(), revisionDate: Date(),
                  content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
                  archivedDate: archived ? Date() : nil)
    }

    override func setUp() async throws {
        try await super.setUp()
        vault = MockVaultRepository()
        useCase = SpyArchiveUseCase()
        sut = makeVaultBrowserViewModel(vault: vault, search: SearchVaultUseCaseImpl(vault: vault), setArchived: useCase)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition not met in time")
    }

    func testCanSetArchived_followsServerSupportAndTrash() async throws {
        vault.stubbedArchiveSupported = true
        sut.refreshCounts()
        try await waitUntil { self.sut.isArchiveSupported }
        XCTAssertTrue(sut.canSetArchived(item("a")))
        XCTAssertTrue(sut.canSetArchived(item("b", archived: true)))
        XCTAssertFalse(sut.canSetArchived(item("c", deleted: true)), "not on a trashed item")
        // No premium or permission gate: the archive state is per user, and a refusal shows the
        // server's message (spec scenario "No premium check"; verify 2026-10-31).
        let readOnlyOrgItem = VaultItem(id: "d", name: "d", isFavorite: false, isDeleted: false, creationDate: Date(),
                                        revisionDate: Date(), content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
                                        organizationId: "org-1", editBlock: .unsupportedFormat)
        XCTAssertTrue(sut.canSetArchived(readOnlyOrgItem))

        vault.stubbedArchiveSupported = false
        sut.refreshCounts()
        try await waitUntil { !self.sut.isArchiveSupported }
        XCTAssertFalse(sut.canSetArchived(item("a")), "hidden on a server without archive")
        XCTAssertTrue(sut.canSetArchived(item("b", archived: true)), "an archived item can still be unarchived")
    }

    func testArchive_announcesAndKeepsTheItemSelected() async throws {
        let original = item("a")
        await vault.populate(items: [original], folders: [], organizations: [], collections: [], syncedAt: Date())
        sut.itemSelection = original
        useCase.onExecute = { [vault] _, _ in
            await vault?.populate(items: [original.with(archivedDate: Date())], folders: [], organizations: [],
                                  collections: [], syncedAt: Date())
        }

        await sut.performSetArchived(id: "a", archived: true)

        XCTAssertEqual(useCase.calls.map(\.1), [true])
        XCTAssertEqual(sut.announcement, "Item archived")
        XCTAssertEqual(sut.itemSelection?.id, "a")
        XCTAssertEqual(sut.itemSelection?.isArchived, true, "the selection shows the moved item")
    }

    func testRefusal_showsTheMessage() async {
        useCase.error = VaultError.archiveUnsupported
        await sut.performSetArchived(id: "a", archived: true)
        XCTAssertEqual(sut.actionError, "This server doesn't support archiving items.")
        XCTAssertNil(sut.announcement)
    }

    func testArchiveSelection_fallsBackToAllItemsWhenEmpty() async throws {
        sut.sidebarSelection = .archive
        vault.stubbedItemCounts = [.archive: 0]
        sut.refreshCounts()
        try await waitUntil { self.sut.sidebarSelection == .allItems }
    }

    func testUnarchivingTheLastArchivedItem_keepsItSelected() async throws {
        let archived = item("a", archived: true)
        await vault.populate(items: [archived], folders: [], organizations: [], collections: [], syncedAt: Date())
        sut.sidebarSelection = .archive
        try await waitUntil { self.sut.displayedItems.map(\.id) == ["a"] }
        sut.itemSelection = archived
        useCase.onExecute = { [vault] _, _ in
            await vault?.populate(items: [archived.with(archivedDate: nil)], folders: [], organizations: [],
                                  collections: [], syncedAt: Date())
        }
        vault.stubbedItemCounts = [.archive: 0]

        await sut.performSetArchived(id: "a", archived: false)

        try await waitUntil { self.sut.sidebarSelection == .allItems }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sut.itemSelection?.id, "a", "the unarchived item stays selected")
        XCTAssertEqual(sut.itemSelection?.isArchived, false)
    }

    func testArchiveFinishingAfterALock_showsNothingInTheNextSession() async throws {
        useCase.error = VaultError.vaultLocked
        useCase.onExecute = { [sut] _, _ in
            await MainActor.run { sut?.clearSession(); sut?.beginSession() }
        }
        await sut.performSetArchived(id: "a", archived: true)
        XCTAssertNil(sut.actionError, "an error from the ended session is not shown")
        XCTAssertNil(sut.announcement)
    }
}
