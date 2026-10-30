import Foundation
@testable import Prizm

/// Test double for `VaultRepository`.
///
/// Tracks items stored by `SyncRepositoryImpl` via `populate(items:syncedAt:)` and
/// edit operations via `update(_:)`.
@MainActor
final class MockVaultRepository: VaultRepository {

    // MARK: - State

    private(set) var populatedItems: [VaultItem] = []
    private(set) var populatedFolders: [Folder] = []
    private(set) var populatedOrganizations: [Organization] = []
    private(set) var populatedCollections: [OrgCollection] = []
    private(set) var clearVaultCalled: Bool = false
    /// The session token of the last `populate` (nil after the seam variant without one).
    private(set) var lastPopulateSession: VaultSessionToken?

    // MARK: - update(_:) stubbing

    var stubbedUpdateResult: VaultItem?
    var stubbedUpdateError: Error?
    private(set) var updateCallCount: Int = 0
    private(set) var lastUpdatedDraft: DraftVaultItem?

    // MARK: - VaultRepository (write side)

    func populate(items: [VaultItem], folders: [Folder], organizations: [Organization],
                  collections: [OrgCollection], syncedAt: Date, session: VaultSessionToken) async {
        lastPopulateSession    = session
        populatedItems         = items
        populatedFolders       = folders
        populatedOrganizations = organizations
        populatedCollections   = collections
    }

    /// The test seam without a token; records no session.
    func populate(items: [VaultItem], folders: [Folder], organizations: [Organization],
                  collections: [OrgCollection], syncedAt: Date) async {
        lastPopulateSession    = nil
        populatedItems         = items
        populatedFolders       = folders
        populatedOrganizations = organizations
        populatedCollections   = collections
    }

    func clearVault() async {
        populatedItems         = []
        populatedFolders       = []
        populatedOrganizations = []
        populatedCollections   = []
        clearVaultCalled       = true
    }

    // MARK: - VaultRepository (read side)

    /// How often `allItems()` was called. The vault browser reads it only to refresh the selected
    /// item, so a test can wait for that refresh instead of sleeping.
    private(set) var allItemsCallCount = 0

    func allItems() async throws -> [VaultItem] {
        allItemsCallCount += 1
        return populatedItems
    }

    func folders() async throws -> [Folder] { populatedFolders }

    func organizations() async throws -> [Organization] { populatedOrganizations }

    func collections() async throws -> [OrgCollection] { populatedCollections }

    func items(for collection: String) async throws -> [VaultItem] {
        populatedItems.filter { $0.collectionIds.contains(collection) }
    }

    func items(for selection: SidebarSelection) async throws -> [VaultItem] {
        switch selection {
        case .allItems:
            return populatedItems
        case .favorites:
            return populatedItems.filter(\.isFavorite)
        case .type(let itemType):
            return populatedItems.filter { $0.content.matchesType(itemType) }
        case .folder(let folderId):
            return populatedItems.filter { $0.folderId == folderId }
        case .trash:
            return populatedItems.filter(\.isDeleted)
        case .verificationCodes:
            return populatedItems.filter { item in
                guard !item.isDeleted, case .login(let l) = item.content, let t = l.totp else { return false }
                return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .newFolder:
            return []
        case .archive:
            return populatedItems.filter { !$0.isDeleted && $0.isArchived }
        case .noFolder:
            return populatedItems.filter { $0.isActive && $0.folderId == nil }
        case .myVault:
            return populatedItems.filter { $0.isActive && $0.organizationId == nil }
        case .organization(let orgId):
            let orgColIds = Set(populatedCollections.filter { $0.organizationId == orgId }.map(\.id))
            return populatedItems.filter { $0.collectionIds.contains(where: { orgColIds.contains($0) }) }
        case .collection(let colId):
            return populatedItems.filter { $0.collectionIds.contains(colId) }
        case .newCollection:
            return []
        }
    }

    func searchItems(query: String, in selection: SidebarSelection) async throws -> [VaultItem] {
        let base = try await items(for: selection)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var stubbedItemCounts: [SidebarSelection: Int] = [:]
    func itemCounts() async throws -> [SidebarSelection: Int] { stubbedItemCounts }

    private(set) var itemDetailCallCount = 0

    func itemDetail(id: String) async throws -> VaultItem {
        itemDetailCallCount += 1
        guard let item = populatedItems.first(where: { $0.id == id }) else {
            throw VaultError.itemNotFound(id)
        }
        return item
    }

    func update(_ draft: DraftVaultItem) async throws -> VaultItem {
        updateCallCount += 1
        lastUpdatedDraft = draft
        if let error = stubbedUpdateError { throw error }
        guard let result = stubbedUpdateResult else {
            throw VaultError.itemNotFound(draft.id)
        }
        return result
    }

    // MARK: - create(_:) stubbing

    var stubbedCreateResult: VaultItem?
    var stubbedCreateError: Error?
    private(set) var createCallCount: Int = 0
    private(set) var lastCreatedDraft: DraftVaultItem?

    func create(_ draft: DraftVaultItem) async throws -> VaultItem {
        createCallCount += 1
        lastCreatedDraft = draft
        if let error = stubbedCreateError { throw error }
        guard let result = stubbedCreateResult else {
            return VaultItem(draft)
        }
        return result
    }

    // MARK: - deleteItem stubbing

    var stubbedDeleteError: Error?
    private(set) var deleteCallCount: Int = 0
    private(set) var lastDeletedId: String?

    func deleteItem(id: String) async throws {
        deleteCallCount += 1
        lastDeletedId = id
        if let error = stubbedDeleteError { throw error }
        populatedItems.removeAll { $0.id == id }
    }

    // MARK: - permanentDeleteItem stubbing

    var stubbedPermanentDeleteError: Error?
    private(set) var permanentDeleteCallCount: Int = 0
    private(set) var lastPermanentDeletedId: String?

    var stubbedPermanentDeleteItemsError: Error?
    private(set) var permanentDeleteItemsCalls: [[String]] = []

    @discardableResult
    func permanentDeleteItems(ids: [String]) async throws -> Int {
        permanentDeleteItemsCalls.append(ids)
        if let error = stubbedPermanentDeleteItemsError { throw error }
        let before = populatedItems.count
        populatedItems.removeAll { ids.contains($0.id) && $0.isDeleted }
        return before - populatedItems.count
    }

    func permanentDeleteItem(id: String) async throws {
        permanentDeleteCallCount += 1
        lastPermanentDeletedId = id
        if let error = stubbedPermanentDeleteError { throw error }
        populatedItems.removeAll { $0.id == id }
    }

    // MARK: - passwordHistory stubbing

    var stubbedPasswordHistory: [PasswordHistoryEntry] = []
    var stubbedPasswordHistoryError: Error?
    private(set) var passwordHistoryRequests: [String] = []

    func passwordHistory(itemId: String) async throws -> [PasswordHistoryEntry] {
        passwordHistoryRequests.append(itemId)
        if let error = stubbedPasswordHistoryError { throw error }
        return stubbedPasswordHistory
    }

    // MARK: - archive stubbing

    var stubbedArchiveSupported = true
    var stubbedSetArchivedError: Error?
    private(set) var setArchivedCalls: [(id: String, archived: Bool)] = []

    func setArchived(id: String, archived: Bool) async throws {
        setArchivedCalls.append((id, archived))
        if let error = stubbedSetArchivedError { throw error }
    }

    func isArchiveSupported() async -> Bool { stubbedArchiveSupported }

    // MARK: - restoreItem stubbing

    var stubbedRestoreError: Error?
    private(set) var restoreCallCount: Int = 0
    private(set) var lastRestoredId: String?

    func restoreItem(id: String) async throws {
        restoreCallCount += 1
        lastRestoredId = id
        if let error = stubbedRestoreError { throw error }
    }

    // MARK: - updateAttachments stubbing

    private(set) var updateAttachmentsCallCount: Int = 0
    private(set) var lastUpdatedAttachments: [Attachment]?
    private(set) var lastUpdateAttachmentsCipherId: String?

    func updateAttachments(_ attachments: [Attachment], for cipherId: String) async {
        updateAttachmentsCallCount += 1
        lastUpdatedAttachments = attachments
        lastUpdateAttachmentsCipherId = cipherId
        // Patch in-memory state so allItems() reflects the update
        if let idx = populatedItems.firstIndex(where: { $0.id == cipherId }) {
            let old = populatedItems[idx]
            populatedItems[idx] = VaultItem(
                id:             old.id,
                name:           old.name,
                isFavorite:     old.isFavorite,
                isDeleted:      old.isDeleted,
                creationDate:   old.creationDate,
                revisionDate:   old.revisionDate,
                content:        old.content,
                reprompt:       old.reprompt,
                attachments:    attachments,
                folderId:       old.folderId,
                organizationId: old.organizationId,
                collectionIds:  old.collectionIds
            )
        }
    }

    // MARK: - Folder CRUD stubbing

    var stubbedCreateFolderResult: Folder?
    var stubbedCreateFolderError: Error?

    func createFolder(name: String) async throws -> Folder {
        if let error = stubbedCreateFolderError { throw error }
        let folder = stubbedCreateFolderResult ?? Folder(id: UUID().uuidString, name: name)
        populatedFolders.append(folder)
        return folder
    }

    func renameFolder(id: String, name: String) async throws -> Folder {
        let folder = Folder(id: id, name: name)
        if let idx = populatedFolders.firstIndex(where: { $0.id == id }) {
            populatedFolders[idx] = folder
        }
        return folder
    }

    var stubbedDeleteFolderError: Error?

    func deleteFolder(id: String) async throws {
        if let error = stubbedDeleteFolderError { throw error }
        populatedFolders.removeAll { $0.id == id }
    }

    func moveItemToFolder(itemId: String, folderId: String?) async throws {}

    // MARK: - setFavorite stubbing

    var stubbedSetFavoriteError: Error?
    private(set) var setFavoriteCalls: [(itemId: String, isFavorite: Bool)] = []

    /// Flips the cached item like the real repository; throws `stubbedSetFavoriteError` if set.
    /// Runs while a favorite request is "in flight", to hold it there.
    var whileSetFavoriteInFlight: (() async -> Void)?

    /// Requests finished (success or failure), and the most that were open at once.
    private(set) var setFavoriteCompletions = 0
    private(set) var maxConcurrentSetFavorite = 0
    private var openSetFavorite = 0

    func setFavorite(itemId: String, isFavorite: Bool) async throws -> VaultItem {
        setFavoriteCalls.append((itemId, isFavorite))
        openSetFavorite += 1
        maxConcurrentSetFavorite = max(maxConcurrentSetFavorite, openSetFavorite)
        await whileSetFavoriteInFlight?()
        openSetFavorite -= 1
        setFavoriteCompletions += 1
        if let error = stubbedSetFavoriteError { throw error }
        guard let idx = populatedItems.firstIndex(where: { $0.id == itemId }) else {
            throw VaultError.itemNotFound(itemId)
        }
        populatedItems[idx] = populatedItems[idx].with(isFavorite: isFavorite)
        return populatedItems[idx]
    }
    func moveItemsToFolder(itemIds: [String], folderId: String?) async throws {}

    // MARK: - Collection CRUD stubbing

    var stubbedCreateCollectionResult: OrgCollection?
    var stubbedCreateCollectionError: Error?
    private(set) var createCollectionCallCount: Int = 0
    private(set) var lastCreateCollectionName: String?
    private(set) var lastCreateCollectionOrgId: String?

    func createCollection(name: String, organizationId: String) async throws -> OrgCollection {
        createCollectionCallCount += 1
        lastCreateCollectionName  = name
        lastCreateCollectionOrgId = organizationId
        if let err = stubbedCreateCollectionError { throw err }
        if let result = stubbedCreateCollectionResult { return result }
        let col = OrgCollection(id: UUID().uuidString, organizationId: organizationId, name: name)
        populatedCollections.append(col)
        return col
    }

    var stubbedRenameCollectionResult: OrgCollection?
    var stubbedRenameCollectionError: Error?
    private(set) var renameCollectionCallCount: Int = 0

    func renameCollection(id: String, organizationId: String, name: String) async throws -> OrgCollection {
        renameCollectionCallCount += 1
        if let err = stubbedRenameCollectionError { throw err }
        let col = stubbedRenameCollectionResult
            ?? OrgCollection(id: id, organizationId: organizationId, name: name)
        if let idx = populatedCollections.firstIndex(where: { $0.id == id }) {
            populatedCollections[idx] = col
        }
        return col
    }

    var stubbedDeleteCollectionError: Error?
    private(set) var deleteCollectionCallCount: Int = 0
    private(set) var lastDeleteCollectionId: String?
    private(set) var lastDeleteCollectionOrgId: String?

    func deleteCollection(id: String, organizationId: String) async throws {
        deleteCollectionCallCount += 1
        lastDeleteCollectionId    = id
        lastDeleteCollectionOrgId = organizationId
        if let err = stubbedDeleteCollectionError { throw err }
        populatedCollections.removeAll { $0.id == id }
    }

}

// MARK: - ItemContent helper

private extension ItemContent {
    func matchesType(_ type: ItemType) -> Bool {
        switch (self, type) {
        case (.login,       .login):      return true
        case (.card,        .card):       return true
        case (.identity,    .identity):   return true
        case (.secureNote,  .secureNote): return true
        case (.sshKey,      .sshKey):     return true
        default:                          return false
        }
    }
}
