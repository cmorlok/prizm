import Foundation

/// In-memory vault store: write side used by `SyncRepositoryImpl`, read side used by use cases.
/// Implemented by `VaultRepositoryImpl` (a dedicated `actor`) in the Data layer.
/// All methods are `async` — callers must `await` them regardless of their own isolation context.
protocol VaultRepository: AnyObject, Sendable {

    /// All non-deleted vault items, sorted alphabetically by name (case-insensitive).
    func allItems() async throws -> [VaultItem]

    /// Items matching the given sidebar selection, sorted alphabetically.
    func items(for selection: SidebarSelection) async throws -> [VaultItem]

    /// Case-insensitive substring search scoped to the active sidebar selection.
    /// Searches type-specific fields per FR-012:
    /// - Login:      name, username, URIs
    /// - Card:       name, cardholderName
    /// - Identity:   name, email, company
    /// - SecureNote: name
    /// - SSHKey:     name
    func searchItems(query: String, in selection: SidebarSelection) async throws -> [VaultItem]

    /// Cached item counts keyed by `SidebarSelection`. O(1) — served from a pre-built index.
    func itemCounts() async throws -> [SidebarSelection: Int]

    /// Returns the fully-decrypted detail for a single item.
    /// Not cached — re-decrypts on every call (decrypt on demand, per spec).
    func itemDetail(id: String) async throws -> VaultItem

    /// Replaces the in-memory vault store and rebuilds all read indexes.
    /// Called by `SyncRepositoryImpl` after a successful sync.
    func populate(items: [VaultItem], folders: [Folder], organizations: [Organization],
                  collections: [OrgCollection], syncedAt: Date) async

    /// All organizations the user belongs to, sorted alphabetically by name.
    func organizations() async throws -> [Organization]

    /// All collections across all organizations, sorted alphabetically by name.
    func collections() async throws -> [OrgCollection]

    /// Items assigned to the given collection, sorted alphabetically by name.
    func items(for collection: String) async throws -> [VaultItem]

    /// Clears the in-memory vault store and all indexes. Called on lock and sign-out.
    func clearVault() async

    /// All folders, sorted alphabetically by name (case-insensitive).
    func folders() async throws -> [Folder]

    /// Re-encrypts `draft`, calls `PUT /ciphers/{id}`, updates the in-memory cache, and
    /// returns the server-confirmed `VaultItem` decoded from the API response.
    func update(_ draft: DraftVaultItem) async throws -> VaultItem

    /// Soft-deletes the item with `id` by calling `PUT /ciphers/{id}/delete`.
    func deleteItem(id: String) async throws

    /// Permanently removes the trashed item with `id` by calling `DELETE /ciphers/{id}`.
    func permanentDeleteItem(id: String) async throws
    /// Permanently deletes the given items if they are in Trash; ids of items that are not in
    /// Trash are ignored. Deleted items leave the cache. Returns how many were deleted; if a
    /// request fails, throws `PermanentDeleteError` after trying the rest.
    @discardableResult
    func permanentDeleteItems(ids: [String]) async throws -> Int

    /// Restores a trashed item by calling `PUT /ciphers/{id}/restore`.
    func restoreItem(id: String) async throws

    /// Encrypts a new `draft`, calls `POST /api/ciphers`, inserts the server-confirmed item
    /// into the in-memory cache, and returns it.
    func create(_ draft: DraftVaultItem) async throws -> VaultItem

    /// Replaces the `attachments` array for the vault item identified by `cipherId`,
    /// patching the in-memory cache without a full re-sync.
    func updateAttachments(_ attachments: [Attachment], for cipherId: String) async

    // MARK: - Folder CRUD

    func createFolder(name: String) async throws -> Folder
    func renameFolder(id: String, name: String) async throws -> Folder
    func deleteFolder(id: String) async throws

    // MARK: - Move to folder

    func moveItemToFolder(itemId: String, folderId: String?) async throws
    func moveItemsToFolder(itemIds: [String], folderId: String?) async throws
    /// Marks or unmarks an item as favorite on the server and in the cache; returns the updated item.
    func setFavorite(itemId: String, isFavorite: Bool) async throws -> VaultItem

    // MARK: - Collection CRUD

    func createCollection(name: String, organizationId: String) async throws -> OrgCollection
    func renameCollection(id: String, organizationId: String, name: String) async throws -> OrgCollection
    func deleteCollection(id: String, organizationId: String) async throws

}

// MARK: - Errors

/// A bulk permanent delete in which at least one request failed.
nonisolated struct PermanentDeleteError: Error {
    /// Items deleted by the requests that succeeded.
    let deleted: Int
    /// The first failure.
    let underlying: Error
}

nonisolated enum VaultError: Error, LocalizedError {
    case vaultLocked
    case decryptionFailed(String)
    case itemNotFound(String)
    /// The server answered a favorite or folder change without saving it. Bitwarden servers on the
    /// MySQL, PostgreSQL or SQLite backend do this (fix-favorite-and-folder-partial-updates).
    case partialUpdateNotSaved
    /// An org item was to be saved but its organization key is not available. Raised instead of
    /// encrypting with the personal key (fix-org-key-required-on-write).
    case organizationKeyUnavailable
    /// A collection's access list could not be read, so a rename was not sent: sending a list
    /// Prizm did not read would replace everyone's access (fix-collection-access-on-rename).
    case collectionAccessUnreadable
    /// The user's organization-user id in the sync profile is present but unreadable, so a new
    /// collection cannot be assigned to its creator.
    case organizationMembershipUnreadable
    /// The user id from the last sync is not known, so a create or full update was not sent: the
    /// server rejects a save without it (Vaultwarden 1.37.4, HTTP 422).
    case profileIdUnavailable
    /// A full save of an item Prizm cannot write back was refused before anything was encrypted or
    /// sent. Folder and favorite changes of the same item are not affected.
    case itemNotEditable(EditBlockReason)
    /// Prizm holds no server record for the item, or the draft's organization differs from the stored
    /// record's, so a save has nothing safe to be built over. Nothing was encrypted or sent.
    case itemRecordUnavailable
    /// The item's own key could not be unwrapped, or the key check on the stored name failed, so
    /// Prizm does not know which key the server expects. Nothing was encrypted or sent.
    case itemKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "The vault is locked. Please unlock to continue."
        case .decryptionFailed(let detail):
            return "Decryption failed: \(detail)"
        case .itemNotFound(let id):
            return "Item not found: \(id)"
        case .partialUpdateNotSaved:
            return "The server didn't save this change."
        case .collectionAccessUnreadable:
            return "Couldn't rename the collection. Its access settings could not be read."
        case .organizationMembershipUnreadable:
            return "Couldn't create the collection. Your membership in this organization could not be read."
        case .organizationKeyUnavailable:
            return "This item's organization can't be accessed right now. Lock and unlock Prizm, then try again."
        case .profileIdUnavailable:
            return "Prizm couldn't confirm which account this item belongs to. Lock and unlock Prizm, then try again."
        case .itemNotEditable(let reason):
            return reason.userMessage
        case .itemRecordUnavailable:
            return "Prizm couldn't load this item's latest saved version. Lock and unlock the vault, then try again."
        case .itemKeyUnavailable:
            return "Prizm couldn't load the encryption key for this item. Lock and unlock the vault, then try again."
        }
    }
}
