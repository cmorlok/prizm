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
