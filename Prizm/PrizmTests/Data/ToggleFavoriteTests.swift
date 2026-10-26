import Synchronization
import XCTest
@testable import Prizm

@MainActor
final class ToggleFavoriteTests: XCTestCase {

    private var vault: MockVaultRepository!
    private var sut: VaultBrowserViewModel!

    private let unfavoritedItem = VaultItem(
        id: "1", name: "GitHub", isFavorite: false, isDeleted: false,
        creationDate: .now, revisionDate: .now,
        content: .login(LoginContent(username: "alice", password: nil, uris: [], totp: nil, notes: nil, customFields: []))
    )

    override func setUp() async throws {
        try await super.setUp()
        vault = MockVaultRepository()
        await vault.populate(items: [unfavoritedItem], folders: [], organizations: [], collections: [], syncedAt: .now)
        let syncRepo = MockSyncTimestampRepository(storedDate: nil)
        sut = VaultBrowserViewModel(
            vault:           vault,
            search:          SearchVaultUseCaseImpl(vault: vault),
            delete:          StubDelete(),
            permanentDelete: StubPermanentDelete(),
            restore:         StubRestore(),
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
            getLastSyncDate:  GetLastSyncDateUseCaseImpl(repository: syncRepo)
        )
    }

    func testToggleFavorite_setsFavoriteThroughTheUseCase() async throws {
        sut.toggleFavorite(item: unfavoritedItem)
        try await waitUntil { !self.vault.setFavoriteCalls.isEmpty }

        XCTAssertEqual(vault.setFavoriteCalls.count, 1)
        XCTAssertEqual(vault.setFavoriteCalls.first?.itemId, "1")
        XCTAssertEqual(vault.setFavoriteCalls.first?.isFavorite, true)
        XCTAssertEqual(vault.updateCallCount, 0, "The star must not re-save the whole item")
    }

    func testToggleFavorite_unfavorites() async throws {
        let favoritedItem = unfavoritedItem.with(isFavorite: true)
        await vault.populate(items: [favoritedItem], folders: [], organizations: [], collections: [], syncedAt: .now)

        sut.toggleFavorite(item: favoritedItem)
        try await waitUntil { !self.vault.setFavoriteCalls.isEmpty }

        XCTAssertEqual(vault.setFavoriteCalls.first?.isFavorite, false)
    }

    func testToggleFavorite_selectedItem_showsNewState() async throws {
        sut.itemSelection = unfavoritedItem

        sut.toggleFavorite(item: unfavoritedItem)
        try await waitUntil { self.sut.itemSelection?.isFavorite == true }

        XCTAssertEqual(sut.itemSelection, unfavoritedItem.with(isFavorite: true))
    }

    func testToggleFavorite_failure_showsErrorAndKeepsItem() async throws {
        vault.stubbedSetFavoriteError = APIError.httpError(statusCode: 500, body: "")
        sut.itemSelection = unfavoritedItem

        sut.toggleFavorite(item: unfavoritedItem)
        try await waitUntil { self.sut.actionError != nil }

        let message = try XCTUnwrap(sut.actionError)
        XCTAssertTrue(message.hasPrefix("Couldn't update favorite."), message)
        XCTAssertEqual(sut.itemSelection, unfavoritedItem, "The item's favorite state stays unchanged")
    }

    // MARK: - favorite-toggle-serialisation

    /// Holds requests until opened; opened in `tearDown` too, so a failing test leaves no task spinning.
    private final class Gate: Sendable {
        let isOpen = Mutex(false)
    }
    private let gate = Gate()
    private func holdRequests() {
        vault.whileSetFavoriteInFlight = { [gate] in
            while !gate.isOpen.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }
    private func releaseRequests() { gate.isOpen.withLock { $0 = true } }

    override func tearDown() async throws {
        releaseRequests()
        try await super.tearDown()
    }

    /// Two clicks while the first is saved: both are applied, in order, and the item ends unstarred.
    func testTwoQuickClicks_endInTheLastClicksState() async throws {
        holdRequests()
        sut.itemSelection = unfavoritedItem

        sut.toggleFavorite(item: unfavoritedItem)
        try await waitUntil { self.vault.setFavoriteCalls.count == 1 }
        sut.toggleFavorite(item: unfavoritedItem)   // the view still passes the unconfirmed item
        releaseRequests()
        try await waitUntil(timeout: .seconds(2)) { self.vault.setFavoriteCalls.count == 2 && self.sut.itemSelection?.isFavorite == false }

        XCTAssertEqual(vault.setFavoriteCalls.map(\.isFavorite), [true, false])
        XCTAssertEqual(sut.itemSelection?.isFavorite, false)
    }

    /// Three clicks while the first is saved: the intent equals what was sent, so nothing follows.
    func testThreeQuickClicks_sendOnlyOnce() async throws {
        holdRequests()

        sut.toggleFavorite(item: unfavoritedItem)
        try await waitUntil { self.vault.setFavoriteCalls.count == 1 }
        sut.toggleFavorite(item: unfavoritedItem)
        sut.toggleFavorite(item: unfavoritedItem)
        releaseRequests()
        try await waitUntil { self.vault.setFavoriteCompletions == 1 }
        try await settle()

        XCTAssertEqual(vault.setFavoriteCalls.map(\.isFavorite), [true])
    }

    /// A failed request drops the intent: nothing further is sent, and the next click starts again
    /// from the item's state.
    func testFailure_sendsNothingFurther() async throws {
        holdRequests()
        vault.stubbedSetFavoriteError = APIError.httpError(statusCode: 500, body: "")

        sut.toggleFavorite(item: unfavoritedItem)
        try await waitUntil { self.vault.setFavoriteCalls.count == 1 }
        sut.toggleFavorite(item: unfavoritedItem)
        releaseRequests()
        try await waitUntil { self.sut.actionError != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vault.setFavoriteCalls.count, 1)

        vault.stubbedSetFavoriteError = nil
        sut.toggleFavorite(item: unfavoritedItem)
        try await waitUntil { self.vault.setFavoriteCalls.count == 2 }
        XCTAssertEqual(vault.setFavoriteCalls.last?.isFavorite, true)
    }

    /// A lock while a request is saved: the request from the old session sends nothing further.
    func testLockInFlight_sendsNothingFurther() async throws {
        holdRequests()
        sut.beginSession()

        sut.toggleFavorite(item: unfavoritedItem)
        try await waitUntil { self.vault.setFavoriteCalls.count == 1 }
        sut.toggleFavorite(item: unfavoritedItem)
        sut.clearSession()
        releaseRequests()
        try await waitUntil { self.vault.setFavoriteCompletions == 1 }
        try await settle()

        XCTAssertEqual(vault.setFavoriteCalls.count, 1)
    }

    /// A click in a new session waits for the old session's request for the same item, then is
    /// sent: one request at a time, and the last one sent is the last click (D2).
    func testClickAfterUnlock_waitsForTheOldRequest() async throws {
        holdRequests()
        sut.beginSession()
        sut.toggleFavorite(item: unfavoritedItem)          // old session: true, held
        try await waitUntil { self.vault.setFavoriteCalls.count == 1 }
        sut.clearSession()
        sut.beginSession()

        let afterSync = unfavoritedItem.with(isFavorite: true)
        sut.toggleFavorite(item: afterSync)                // new session: false, queued
        try await settle()
        XCTAssertEqual(vault.setFavoriteCalls.count, 1, "Not sent while the old request is open")

        releaseRequests()
        try await waitUntil { self.vault.setFavoriteCompletions == 2 }

        XCTAssertEqual(vault.setFavoriteCalls.map(\.isFavorite), [true, false])
        XCTAssertEqual(vault.maxConcurrentSetFavorite, 1)
    }

    /// Lets queued main-actor work run.
    private func settle() async throws {
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
    }

    private func waitUntil(timeout: Duration = .milliseconds(500), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class StubDelete: DeleteVaultItemUseCase { func execute(id: String) async throws {} }
private final class StubPermanentDelete: PermanentDeleteVaultItemUseCase { func execute(id: String) async throws {} }
private final class StubRestore: RestoreVaultItemUseCase { func execute(id: String) async throws {} }
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
