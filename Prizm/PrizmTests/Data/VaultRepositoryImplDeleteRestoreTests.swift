import XCTest
@testable import Prizm

// MARK: - VaultRepositoryImplDeleteRestoreTests

/// Integration tests for the delete, restore, and empty-trash operations in
/// `VaultRepositoryImpl`.
///
/// Covers:
///   - deleteItem soft-deletes active items (marks isDeleted, stays in cache)
///   - deleteItem permanently removes already-trashed items from cache
///   - restoreItem marks trashed items as active
///   - items(for: .trash) returns only trashed items
///   - itemCounts includes .trash count
///   - API errors propagate correctly
@MainActor
final class VaultRepositoryImplDeleteRestoreTests: XCTestCase {

    private var sut: VaultRepositoryImpl!
    private var mockAPI: MockPrizmAPIClient!
    private var mockCrypto: MockPrizmCryptoService!

    override func setUp() async throws {
        try await super.setUp()
        mockAPI    = MockPrizmAPIClient()
        mockCrypto = MockPrizmCryptoService()
        sut        = await RepositoryFixtures.vaultRepository(apiClient: mockAPI, crypto: mockCrypto)
    }

    // MARK: - Helpers

    private func makeLogin(
        id: String = UUID().uuidString,
        name: String,
        isDeleted: Bool = false
    ) -> VaultItem {
        VaultItem(
            id: id, name: name, isFavorite: false, isDeleted: isDeleted,
            creationDate: Date(), revisionDate: Date(),
            content: .login(LoginContent(
                username: nil, password: nil, uris: [], totp: nil,
                notes: nil, customFields: []
            ))
        )
    }

    // MARK: - deleteItem (soft-delete active item)

    func testDeleteItem_activeItem_marksDeletedInCache() async throws {
        let item = makeLogin(id: "id-1", name: "Active Item")
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())

        try await sut.deleteItem(id: "id-1")

        let allActive = try await sut.allItems()
        XCTAssertTrue(allActive.isEmpty, "Active list should exclude soft-deleted item")

        let trashed = try await sut.items(for: .trash)
        XCTAssertEqual(trashed.count, 1)
        XCTAssertEqual(trashed[0].id, "id-1")
        XCTAssertTrue(trashed[0].isDeleted)
    }

    func testDeleteItem_activeItem_callsAPIOnce() async throws {
        let item = makeLogin(id: "id-1", name: "Active")
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())

        try await sut.deleteItem(id: "id-1")

        XCTAssertEqual(mockAPI.softDeleteCallCount, 1)
        XCTAssertEqual(mockAPI.lastSoftDeletedId, "id-1")
    }

    func testPermanentDeleteItem_trashedItem_removesFromCache() async throws {
        let item = makeLogin(id: "id-2", name: "Trashed Item", isDeleted: true)
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())

        try await sut.permanentDeleteItem(id: "id-2")

        let trashed = try await sut.items(for: .trash)
        XCTAssertTrue(trashed.isEmpty, "Item should be removed from cache after permanent delete")
    }

    func testPermanentDeleteItem_callsAPIOnce() async throws {
        let item = makeLogin(id: "id-2", name: "Trashed Item", isDeleted: true)
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())

        try await sut.permanentDeleteItem(id: "id-2")

        XCTAssertEqual(mockAPI.permanentDeleteCallCount, 1)
        XCTAssertEqual(mockAPI.lastPermanentDeletedId, "id-2")
    }

    func testDeleteItem_apiError_doesNotUpdateCache() async throws {
        let item = makeLogin(id: "id-3", name: "Item")
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
        mockAPI.softDeleteShouldThrow = APIError.httpError(statusCode: 500, body: "fail")

        do {
            try await sut.deleteItem(id: "id-3")
            XCTFail("Expected error")
        } catch { }

        let active = try await sut.allItems()
        XCTAssertEqual(active.count, 1, "Item should remain active when API call fails")
    }

    // MARK: - restoreItem

    func testRestoreItem_trashedItem_marksActiveInCache() async throws {
        let item = makeLogin(id: "id-4", name: "Trashed", isDeleted: true)
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())

        try await sut.restoreItem(id: "id-4")

        let active = try await sut.allItems()
        XCTAssertEqual(active.count, 1)
        XCTAssertFalse(active[0].isDeleted)

        let trashed = try await sut.items(for: .trash)
        XCTAssertTrue(trashed.isEmpty, "Restored item should not appear in trash")
    }

    func testRestoreItem_callsAPIOnce() async throws {
        let item = makeLogin(id: "id-4", name: "Trashed", isDeleted: true)
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())

        try await sut.restoreItem(id: "id-4")

        XCTAssertEqual(mockAPI.restoreCallCount, 1)
        XCTAssertEqual(mockAPI.lastRestoredId, "id-4")
    }

    func testRestoreItem_apiError_doesNotUpdateCache() async throws {
        let item = makeLogin(id: "id-5", name: "Trashed", isDeleted: true)
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
        mockAPI.restoreShouldThrow = APIError.httpError(statusCode: 503, body: "unavailable")

        do {
            try await sut.restoreItem(id: "id-5")
            XCTFail("Expected error")
        } catch { }

        let trashed = try await sut.items(for: .trash)
        XCTAssertEqual(trashed.count, 1, "Trashed item should remain when API call fails")
    }

    // MARK: - The vault changes while the request is in flight

    // The repository is an actor, so a lock (`clearVault`) or a sync (`populate`) can run while a
    // request waits for the server. The item is looked up again after the request: an index taken
    // before it would trap after a lock and point at another item after a sync.

    func testDeleteItem_vaultClearedDuringRequest_doesNotCrash() async throws {
        await sut.populate(items: [makeLogin(id: "a", name: "A")], folders: [], organizations: [], collections: [], syncedAt: Date())
        let vault = sut!
        mockAPI.whileSoftDeletingCipher = { await vault.clearVault() }

        try await sut.deleteItem(id: "a")

        let all = try await sut.allItems()
        let trashed = try await sut.items(for: .trash)
        XCTAssertTrue(all.isEmpty)
        XCTAssertTrue(trashed.isEmpty, "The lock emptied the cache; the finished delete must not bring an item back")
    }

    func testDeleteItem_cacheReplacedDuringRequest_marksOnlyThatItem() async throws {
        let a = makeLogin(id: "a", name: "A")
        let b = makeLogin(id: "b", name: "B")
        await sut.populate(items: [a, b], folders: [], organizations: [], collections: [], syncedAt: Date())
        let vault = sut!
        // A sync delivered the same items in another order.
        mockAPI.whileSoftDeletingCipher = {
            await vault.populate(items: [b, a], folders: [], organizations: [], collections: [], syncedAt: Date())
        }

        try await sut.deleteItem(id: "a")

        let trashed = try await sut.items(for: .trash)
        let active = try await sut.allItems()
        XCTAssertEqual(trashed.map(\.id), ["a"])
        XCTAssertEqual(active.map(\.id), ["b"])
    }

    func testPermanentDeleteItem_vaultClearedDuringRequest_doesNotCrash() async throws {
        await sut.populate(items: [makeLogin(id: "t1", name: "T1", isDeleted: true)],
                           folders: [], organizations: [], collections: [], syncedAt: Date())
        let vault = sut!
        mockAPI.whileDeletingCipher = { await vault.clearVault() }

        try await sut.permanentDeleteItem(id: "t1")

        XCTAssertEqual(mockAPI.permanentDeleteCallCount, 1)
        let trashed = try await sut.items(for: .trash)
        XCTAssertTrue(trashed.isEmpty)
    }

    func testPermanentDeleteItem_cacheReplacedDuringRequest_removesOnlyThatItem() async throws {
        let t1 = makeLogin(id: "t1", name: "T1", isDeleted: true)
        let t2 = makeLogin(id: "t2", name: "T2", isDeleted: true)
        await sut.populate(items: [t1, t2], folders: [], organizations: [], collections: [], syncedAt: Date())
        let vault = sut!
        mockAPI.whileDeletingCipher = {
            await vault.populate(items: [t2, t1], folders: [], organizations: [], collections: [], syncedAt: Date())
        }

        try await sut.permanentDeleteItem(id: "t1")

        let trashed = try await sut.items(for: .trash)
        XCTAssertEqual(trashed.map(\.id), ["t2"])
    }

    func testRestoreItem_vaultClearedDuringRequest_doesNotCrash() async throws {
        await sut.populate(items: [makeLogin(id: "r1", name: "R1", isDeleted: true)],
                           folders: [], organizations: [], collections: [], syncedAt: Date())
        let vault = sut!
        mockAPI.whileRestoringCipher = { await vault.clearVault() }

        try await sut.restoreItem(id: "r1")

        let all = try await sut.allItems()
        let trashed = try await sut.items(for: .trash)
        XCTAssertTrue(all.isEmpty, "The lock emptied the cache; the finished restore must not bring an item back")
        XCTAssertTrue(trashed.isEmpty)
    }

    func testRestoreItem_cacheReplacedDuringRequest_restoresOnlyThatItem() async throws {
        let r1 = makeLogin(id: "r1", name: "R1", isDeleted: true)
        let r2 = makeLogin(id: "r2", name: "R2", isDeleted: true)
        await sut.populate(items: [r1, r2], folders: [], organizations: [], collections: [], syncedAt: Date())
        let vault = sut!
        mockAPI.whileRestoringCipher = {
            await vault.populate(items: [r2, r1], folders: [], organizations: [], collections: [], syncedAt: Date())
        }

        try await sut.restoreItem(id: "r1")

        let active = try await sut.allItems()
        let trashed = try await sut.items(for: .trash)
        XCTAssertEqual(active.map(\.id), ["r1"])
        XCTAssertEqual(trashed.map(\.id), ["r2"])
    }

    // MARK: - items(for: .trash)

    func testItemsForTrash_onlyReturnsTrashedItems() async throws {
        let active  = makeLogin(name: "Active",  isDeleted: false)
        let trashed = makeLogin(name: "Trashed", isDeleted: true)
        await sut.populate(items: [active, trashed], folders: [], organizations: [], collections: [], syncedAt: Date())

        let result = try await sut.items(for: .trash)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Trashed")
    }

    func testItemsForTrash_empty_returnsEmpty() async throws {
        await sut.populate(items: [makeLogin(name: "Active")], folders: [], organizations: [], collections: [], syncedAt: Date())
        let result = try await sut.items(for: .trash)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - itemCounts(.trash)

    func testItemCounts_includesTrashCount() async throws {
        let items: [VaultItem] = [
            makeLogin(name: "A", isDeleted: false),
            makeLogin(name: "B", isDeleted: true),
            makeLogin(name: "C", isDeleted: true),
        ]
        await sut.populate(items: items, folders: [], organizations: [], collections: [], syncedAt: Date())

        let counts = try await sut.itemCounts()
        XCTAssertEqual(counts[.trash], 2, "Trash count should reflect all isDeleted items")
        XCTAssertEqual(counts[.allItems], 1, "Active count should exclude deleted items")
    }
}
