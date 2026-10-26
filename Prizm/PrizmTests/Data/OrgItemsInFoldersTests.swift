import XCTest
@testable import Prizm

/// Folders are personal but hold any item the user can see, organization items included
/// (openspec change org-items-in-personal-folders).
@MainActor
final class OrgItemsInFoldersTests: XCTestCase {

    private var sut: VaultRepositoryImpl!
    private var api: MockPrizmAPIClient!
    private let orgKeys = CryptoKeys(encryptionKey: Data(repeating: 0x33, count: 32), macKey: Data(repeating: 0x44, count: 32))

    private let orgItem = VaultItem(
        id: "org-item", name: "Shared", isFavorite: false, isDeleted: false,
        creationDate: Date(), revisionDate: Date(),
        content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
        folderId: "f1", organizationId: "org-1", collectionIds: ["col-a"]
    )
    private let personalItem = VaultItem(
        id: "personal", name: "Mine", isFavorite: false, isDeleted: false,
        creationDate: Date(), revisionDate: Date(),
        content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
        folderId: "f1"
    )

    override func setUp() async throws {
        try await super.setUp()
        api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        let vaultKeys = CryptoKeys(encryptionKey: Data(repeating: 0x11, count: 32), macKey: Data(repeating: 0x22, count: 32))
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        sut = VaultRepositoryImpl(apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache)
        await sut.populate(items: [orgItem, personalItem],
                           folders: [Folder(id: "f1", name: "Work"), Folder(id: "f2", name: "Home")],
                           organizations: [], collections: [OrgCollection(id: "col-a", organizationId: "org-1", name: "A")],
                           syncedAt: Date())
    }

    // MARK: - 2.1 Folder list and count include org items

    func testFolder_listsOrgItemsFiledThere() async throws {
        let ids = try await sut.items(for: .folder("f1")).map(\.id)
        XCTAssertEqual(Set(ids), ["org-item", "personal"])
        let counts = try await sut.itemCounts()
        XCTAssertEqual(counts[.folder("f1")], 2)
    }

    // MARK: - 3.1 Moving keeps the organization

    func testMoveSeveralItems_orgItemStaysInItsCollection() async throws {
        try await sut.moveItemsToFolder(itemIds: [orgItem.id], folderId: "f2")

        let inHome = try await sut.items(for: .folder("f2")).map(\.id)
        XCTAssertEqual(inHome, ["org-item"])
        let inCollection = try await sut.items(for: .collection("col-a")).map(\.id)
        XCTAssertEqual(inCollection, ["org-item"], "Still in its collection")
        let moved = try await sut.itemDetail(id: orgItem.id)
        XCTAssertEqual(moved.organizationId, "org-1")
    }

    /// Dragging one item onto a folder goes through /partial (`moveItemToFolder`).
    func testDragOneOrgItem_usesPartialAndKeepsTheOrganization() async throws {
        try await sut.moveItemToFolder(itemId: orgItem.id, folderId: "f2")

        XCTAssertEqual(api.partialUpdates.map(\.folderId), ["f2"])
        let moved = try await sut.itemDetail(id: orgItem.id)
        XCTAssertEqual(moved.folderId, "f2")
        XCTAssertEqual(moved.organizationId, "org-1")
        XCTAssertEqual(moved.collectionIds, ["col-a"])
    }

    func testDeleteFolder_keepsTheOrgItemInItsCollection() async throws {
        try await sut.deleteFolder(id: "f1")

        let item = try await sut.itemDetail(id: orgItem.id)
        XCTAssertNil(item.folderId)
        XCTAssertEqual(item.organizationId, "org-1")
        XCTAssertEqual(item.collectionIds, ["col-a"])
    }

    // MARK: - 4.1 The edit sheet saves a folder for an org item

    /// A folder-only change needs read access only: it goes through /partial, never a full PUT,
    /// which the server refuses for an item in a read-only collection.
    func testUpdate_folderOnlyChange_usesPartialNotPut() async throws {
        var draft = DraftVaultItem(orgItem)
        draft.folderId = "f2"

        let saved = try await sut.update(draft)

        XCTAssertEqual(api.partialUpdates.count, 1)
        XCTAssertEqual(api.partialUpdates.first?.folderId, "f2")
        XCTAssertEqual(api.updateCipherCallCount, 0, "No full PUT")
        XCTAssertEqual(api.updateCipherCollectionsCallCount, 0)
        XCTAssertEqual(saved.folderId, "f2")
        XCTAssertEqual(saved.organizationId, "org-1")
        XCTAssertEqual(saved.collectionIds, ["col-a"])
    }

    func testUpdate_folderAndOtherChange_sendsFolderInTheFullPut() async throws {
        var draft = DraftVaultItem(orgItem)
        draft.folderId = "f2"
        draft.name = "Shared, renamed"

        _ = try await sut.update(draft)

        XCTAssertEqual(api.partialUpdates.count, 0)
        XCTAssertEqual(api.lastUpdatedCipher?.folderId, "f2")
        XCTAssertEqual(api.lastUpdatedCipher?.organizationId, "org-1")
        XCTAssertEqual(api.lastUpdatedCipherCollections?.collectionIds, ["col-a"])
    }

    private final class CapturingEdit: EditVaultItemUseCase {
        let called: XCTestExpectation
        private(set) var saved: DraftVaultItem?
        init(called: XCTestExpectation) { self.called = called }
        func execute(draft: DraftVaultItem) async throws -> VaultItem {
            saved = draft
            called.fulfill()
            return VaultItem(draft)
        }
    }

    func testEditSheet_orgItemWithNewFolder_keepsOrganizationAndCollections() async throws {
        let edit = CapturingEdit(called: expectation(description: "saved"))
        let viewModel = ItemEditViewModel(item: orgItem, useCase: edit, folders: [Folder(id: "f2", name: "Home")])
        viewModel.draft.folderId = "f2"

        viewModel.save()
        await fulfillment(of: [edit.called], timeout: 5)

        XCTAssertEqual(edit.saved?.folderId, "f2")
        XCTAssertEqual(edit.saved?.organizationId, "org-1")
        XCTAssertEqual(edit.saved?.collectionIds, ["col-a"])
    }
}
