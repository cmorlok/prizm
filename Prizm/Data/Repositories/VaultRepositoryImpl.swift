import Foundation
import os.log

// MARK: - VaultRepositoryImpl

/// In-memory vault store, populated by `SyncRepositoryImpl` after each sync.
///
/// All items are held in a flat `[VaultItem]` array. `populate()` rebuilds three
/// pre-computed indexes so that read methods are O(1) lookups instead of O(n) scans.
/// Every write method that mutates the raw stores calls `buildIndexes()` to keep the
/// cache consistent without waiting for the next sync.
///
/// Thread safety: this type is a Swift `actor`. All mutations and reads execute on the
/// actor's cooperative-thread-pool executor — never on the main thread.
actor VaultRepositoryImpl: VaultRepository {

    private let logger = Logger(subsystem: "com.prizm", category: "VaultRepository")

    // MARK: - Dependencies (write path)

    private let apiClient:   any PrizmAPIClientProtocol
    private let crypto:      any PrizmCryptoService
    // `nonisolated`: CipherMapper is Sendable with no mutable state; marking it nonisolated
    // allows the actor init to be called from @MainActor without an actor hop.
    nonisolated private let mapper: CipherMapper
    private let orgKeyCache: OrgKeyCache
    /// The profile id of the last sync, sent as `encryptedFor` on creates and full updates.
    private let profileIds: ProfileIdCache
    /// The last server record of each item; filled by sync, create and update, emptied here.
    private let recordStore: RawCipherStore

    // MARK: - Raw stores

    private var items: [VaultItem] = []
    private var folderStore: [Folder] = []
    private var organizationStore: [Organization] = []
    private var collectionStore: [OrgCollection] = []

    /// Internal sync timestamp; not exposed on the protocol (use `GetLastSyncDateUseCase`).
    private(set) var lastSyncedAt: Date? = nil

    // MARK: - Read indexes (rebuilt by buildIndexes() after every mutation)

    /// Pre-filtered, sorted item lists keyed by SidebarSelection.
    private var _bySelection: [SidebarSelection: [VaultItem]]

    /// Pre-computed counts keyed by SidebarSelection.
    private var _counts: [SidebarSelection: Int]

    /// Maps orgId → Set<collectionId> for O(1) org-membership tests.
    private var _orgCollectionIds: [String: Set<String>]

    // MARK: - Init

    // `nonisolated` avoids a Swift 6 strict-concurrency error when this init is called
    // from a `@MainActor` context (e.g. AppContainer): stored properties are initialized
    // before the actor is "live", so the actor executor is not yet involved.
    init(
        apiClient:   any PrizmAPIClientProtocol,
        crypto:      any PrizmCryptoService,
        mapper:      CipherMapper = CipherMapper(),
        orgKeyCache: OrgKeyCache = OrgKeyCache(),
        // No default: one holder is shared with `SyncRepositoryImpl`, which fills it.
        profileIds:  ProfileIdCache,
        // No default: one store is shared with `SyncRepositoryImpl`, which fills it.
        recordStore: RawCipherStore
    ) {
        self.apiClient         = apiClient
        self.crypto            = crypto
        self.mapper            = mapper
        self.orgKeyCache       = orgKeyCache
        self.profileIds        = profileIds
        self.recordStore       = recordStore

        // Pre-populate static keys with zero counts so itemCounts() returns 0 (not nil)
        // before the first populate() / buildIndexes() call (e.g. empty-vault tests).
        var bySelection: [SidebarSelection: [VaultItem]] = [
            .allItems: [], .favorites: [], .trash: []
        ]
        var counts: [SidebarSelection: Int] = [
            .allItems: 0, .favorites: 0, .trash: 0
        ]
        for type in ItemType.allCases {
            bySelection[.type(type)] = []
            counts[.type(type)] = 0
        }
        self._bySelection      = bySelection
        self._counts           = counts
        self._orgCollectionIds = [:]
    }

    // MARK: - Write side (called by SyncRepositoryImpl)

    func populate(items: [VaultItem], folders: [Folder], organizations: [Organization],
                  collections: [OrgCollection], syncedAt: Date) async {
        self.items             = items
        self.folderStore       = folders
        self.organizationStore = organizations
        self.collectionStore   = collections
        self.lastSyncedAt      = syncedAt
        buildIndexes()
        logger.info("Vault populated: \(items.count) item(s), \(folders.count) folder(s), \(organizations.count) org(s), \(collections.count) collection(s)")
    }

    func clearVault() async {
        // First: lock and sign-out both reach this hook (RootViewModel), so neither the id nor the
        // records outlive the session. The invalidation is the very first statement, before any
        // suspension: it is synchronous, so a save that resumes on this actor after this call sees
        // the lock at its next `isCurrent` check, and `clear()` below only has to empty the store.
        // The second bump `clear()` makes is harmless; the first one is what the item-cache checks
        // in `update` and `create` rely on.
        recordStore.invalidate()
        await recordStore.clear()
        await profileIds.clear()
        items             = []
        folderStore       = []
        organizationStore = []
        collectionStore   = []
        lastSyncedAt      = nil
        _bySelection      = [:]
        _counts           = [:]
        _orgCollectionIds = [:]
        logger.info("Vault cleared")
    }

    // MARK: - Index builder

    private func buildIndexes() {
        // Local staging variable — not stored; _bySelection[.allItems] serves the same role.
        let active = items.filter { !$0.isDeleted }

        // Build org-collection map first: used by both _bySelection and _counts.
        var orgColIds: [String: Set<String>] = [:]
        for col in collectionStore {
            orgColIds[col.organizationId, default: []].insert(col.id)
        }
        _orgCollectionIds = orgColIds

        // Build _bySelection
        var bySelection: [SidebarSelection: [VaultItem]] = [:]
        bySelection[.allItems]  = sorted(active)
        bySelection[.favorites] = sorted(active.filter(\.isFavorite))
        bySelection[.trash]     = sorted(items.filter(\.isDeleted))
        // Verification Codes: every non-trashed Login with a non-blank seed. Whether the seed is
        // *usable* is decided at display time, so items with bad seeds still appear (as
        // "unavailable") and the user can see they exist.
        bySelection[.verificationCodes] = sorted(active.filter(\.hasTOTPSeed))

        for type in ItemType.allCases {
            bySelection[.type(type)] = sorted(active.filter { $0.content.matchesItemType(type) })
        }
        for folder in folderStore {
            // Folders are per user and hold org items too: each user files any item they can see,
            // and the sync sends that user's folder for org items (org-items-in-personal-folders).
            bySelection[.folder(folder.id)] = sorted(active.filter { $0.folderId == folder.id })
        }
        // Index by collection — cover all collectionIds referenced in items, not just those
        // present in collectionStore. Items may reference collections that haven't been fetched
        // yet (e.g. before the first full sync), so we union both sources.
        var allCollectionIds = Set(collectionStore.map(\.id))
        for item in active { allCollectionIds.formUnion(item.collectionIds) }
        for colId in allCollectionIds {
            bySelection[.collection(colId)] = sorted(active.filter {
                $0.collectionIds.contains(colId)
            })
        }
        // Index by organization — derive from collectionStore's organizationIds as well as
        // organizationStore, so org filtering works even when organizations: [] is passed to
        // populate() but collections carry orgId metadata.
        var allOrgIds = Set(organizationStore.map(\.id))
        allOrgIds.formUnion(orgColIds.keys)
        for orgId in allOrgIds {
            let colIds = orgColIds[orgId] ?? []
            bySelection[.organization(orgId)] = sorted(active.filter {
                $0.organizationId == orgId ||
                $0.collectionIds.contains(where: { colIds.contains($0) })
            })
        }
        _bySelection = bySelection

        // Derive _counts from _bySelection — no second filtering pass over items.
        var counts: [SidebarSelection: Int] = [:]
        counts[.allItems]  = bySelection[.allItems]?.count  ?? 0
        counts[.favorites] = bySelection[.favorites]?.count ?? 0
        counts[.trash]     = bySelection[.trash]?.count     ?? 0
        counts[.verificationCodes] = bySelection[.verificationCodes]?.count ?? 0
        for type in ItemType.allCases {
            counts[.type(type)] = bySelection[.type(type)]?.count ?? 0
        }
        for folder in folderStore {
            counts[.folder(folder.id)] = bySelection[.folder(folder.id)]?.count ?? 0
        }
        for colId in allCollectionIds {
            counts[.collection(colId)] = bySelection[.collection(colId), default: []].count
        }
        for orgId in allOrgIds {
            counts[.organization(orgId)] = bySelection[.organization(orgId), default: []].count
        }
        _counts = counts
    }

    // MARK: - Read side

    func allItems() async throws -> [VaultItem] {
        _bySelection[.allItems] ?? []
    }

    func folders() async throws -> [Folder] {
        folderStore.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func organizations() async throws -> [Organization] {
        organizationStore.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func collections() async throws -> [OrgCollection] {
        collectionStore.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func items(for collection: String) async throws -> [VaultItem] {
        _bySelection[.collection(collection)] ?? []
    }

    func items(for selection: SidebarSelection) async throws -> [VaultItem] {
        switch selection {
        case .newFolder, .newCollection:
            return []
        default:
            return _bySelection[selection] ?? []
        }
    }

    func searchItems(query: String, in selection: SidebarSelection) async throws -> [VaultItem] {
        let base = _bySelection[selection] ?? []
        guard !query.isEmpty else { return base }
        return base.filter { $0.matchesSearch(query: query) }
    }

    func itemCounts() async throws -> [SidebarSelection: Int] {
        _counts
    }

    func itemDetail(id: String) async throws -> VaultItem {
        guard let item = items.first(where: { $0.id == id }) else {
            throw VaultError.itemNotFound(id)
        }
        return item
    }

    // MARK: - Update (write path — called by EditVaultItemUseCaseImpl)

    /// Saves `draft` over the item's last server record: re-encrypts what the user edited, calls
    /// `PUT /api/ciphers/{id}`, splices the server-confirmed item into the in-memory cache, and
    /// returns it.
    ///
    /// - Security goal: every edited field is re-encrypted with the key the server expects for the
    ///   item before the request leaves the device, and the save fails instead of guessing when that
    ///   key cannot be established. The re-encryption boundary is the call to
    ///   `CipherMapper.toRawCipher(_:overlaying:effectiveKeys:encryptedFor:)`; after it only EncString
    ///   ciphertext exists in the `RawCipher`. Plaintext is never serialised into the JSON body.
    ///   Algorithm: EncString type-2 (AES-256-CBC + HMAC-SHA256); see `CipherMapper` for the full
    ///   algorithm reference and security notes.
    ///
    /// - Check order. Each step fails before anything is encrypted or sent, and a failure changes
    ///   neither the stored record, nor the item cache, nor the caller's draft:
    ///   1. Vault locked → `VaultError.vaultLocked`.
    ///   2. A change of folder or favorite only goes through `/partial` and needs none of the below.
    ///   3. The cached item's edit block → `itemNotEditable`.
    ///   4. The stored server record is missing → `itemRecordUnavailable`.
    ///   5. The stored record's own edit block → `itemNotEditable`.
    ///   6. The draft's organization differs from the record's → `itemRecordUnavailable` (a draft
    ///      cannot move an item between organizations, and its collections are never sent on a guess).
    ///   7. The stored record has no readable revision (missing, empty, not a date, or the epoch)
    ///      → `itemRevisionUnavailable`: without one no revision check can protect the edit.
    ///   8. The pre-check: the draft's revision must equal the stored record's (whole milliseconds,
    ///      `CipherMapper.sameRevision`), else `conflict`. Equality, not order: a draft that is newer
    ///      than the record is just as stale. No request is made.
    ///   9. The active key follows the stored record's organization: that organization's key, or the
    ///      vault key for a personal item. A missing organization key → `organizationKeyUnavailable`.
    ///   10. The profile id for `encryptedFor` → `profileIdUnavailable`.
    ///   11. The effective key: the item's own key unwrapped with the active key, or the active key
    ///       for an item without one. A key that does not unwrap → `itemKeyUnavailable`.
    ///   12. The key check: the stored name must verify and decrypt under that key
    ///       (`CipherMapper.verifyKey`) → `itemKeyUnavailable`.
    ///   13. The overlay: the draft's edits over the stored record.
    ///
    /// - What is NOT done:
    ///   • No fallback to another key at any step. In particular the vault key is never tried for an
    ///     organization item, and the attachment key service (which falls back to the vault key on a
    ///     cache miss) is not used on this path.
    ///   • Biometric re-authentication is not required before writing (see TODO below).
    ///   • Offline writes are not queued; a network failure surfaces as a thrown error
    ///     and leaves the local cache unchanged (see TODO below).
    ///
    /// - Data flow after the checks: the encrypted `RawCipher` is sent via `PUT /api/ciphers/{id}`;
    ///   the server response (not the draft, so its revision date and normalisation are captured) is
    ///   stored as the item's new record and re-mapped to a `VaultItem`; the in-memory cache is
    ///   patched in place so the UI reflects the latest state without a full re-sync.
    ///
    /// - Throws: `VaultError.vaultLocked`, `itemNotEditable`, `itemRecordUnavailable`,
    ///   `itemRevisionUnavailable`, `organizationKeyUnavailable`, `profileIdUnavailable` or
    ///   `itemKeyUnavailable` as above.
    /// - Throws: `VaultError.conflict` from the pre-check, and when the server rejects the PUT as out
    ///   of date (HTTP 400, `APIError.isOutOfDateRejection`). The server copy is untouched and
    ///   nothing is retried.
    /// - Throws: `VaultError.vaultLocked` also when the vault was cleared while the request ran: the
    ///   answer is then dropped unread (nothing decrypted, stored or cached).
    /// - Throws: `APIError` on any other network or HTTP failure.
    /// - Throws: `CipherMapperError` if the response mapper fails.
    func update(_ draft: DraftVaultItem) async throws -> VaultItem {
        // TODO: Require biometric re-auth before encrypting and sending — deferred pending
        // SecureEnclave entitlement approval.

        // First, before any await on the network: `clearVault()` bumps this token, so a lock that
        // lands while the request runs makes the store write and the cache write below refuse. A
        // token read at the write would always be current. Synchronous, so no suspension sits
        // between starting the save and holding the token.
        let storeGeneration = recordStore.currentGeneration()

        let vaultKeys: CryptoKeys
        do {
            vaultKeys = try await crypto.currentKeys()
        } catch PrizmCryptoServiceError.vaultLocked {
            throw VaultError.vaultLocked
        }

        // Folder and favorite are per-user fields. When nothing else changed, they go through
        // /partial, which needs read access only, like the official clients' "partial-edit" mode.
        // A full PUT is refused for an org item in a read-only collection
        // (org-items-in-personal-folders).
        if let cached = items.first(where: { $0.id == draft.id }) {
            var perUserChangeOnly = DraftVaultItem(cached)
            perUserChangeOnly.folderId = draft.folderId
            perUserChangeOnly.isFavorite = draft.isFavorite
            if perUserChangeOnly == draft {
                let updated = try await sendPartial(itemId: draft.id, folderId: draft.folderId, favorite: draft.isFavorite)
                logger.info("Item updated (folder/favorite only): \(draft.id, privacy: .public)")
                return updated ?? cached.with(folderId: draft.folderId).with(isFavorite: draft.isFavorite)
            }
        }

        // Defence in depth behind the disabled Edit button, menu item and shortcut: an item with an
        // edit block never reaches the encryption below. After the /partial branch, which carries no
        // item data and stays available. Nothing is encrypted or sent, and the cache is untouched.
        if let blockReason = items.first(where: { $0.id == draft.id })?.editBlock {
            logger.error("Save refused: item \(draft.id, privacy: .public) cannot be edited (\(String(describing: blockReason), privacy: .public))")
            throw VaultError.itemNotEditable(blockReason)
        }

        // The server's last record of this item: the save is built over it, and without it nothing is
        // sent (there would be no key and no preserved values to base the request on).
        guard let base = await recordStore.record(for: draft.id) else {
            logger.error("Save refused: no stored record for \(draft.id, privacy: .public)")
            throw VaultError.itemRecordUnavailable
        }

        // The stored record's own shape, checked again here: the cached item above can be older than
        // the record (a sync replaced it), and a caller other than the edit sheet reaches this too.
        if let reason = mapper.editBlock(for: base) {
            logger.error("Save refused: stored record of \(draft.id, privacy: .public) cannot be edited (\(String(describing: reason), privacy: .public))")
            throw VaultError.itemNotEditable(reason)
        }

        // The key follows the stored record, never the draft: a draft that names another
        // organization than the record would be encrypted under a key the server does not expect for
        // the item, and its collections would be sent on a guess.
        guard draft.organizationId == base.organizationId else {
            logger.error("Save refused: draft of \(draft.id, privacy: .public) is in \(draft.organizationId?.prefix(8) ?? "personal", privacy: .public), stored record in \(base.organizationId?.prefix(8) ?? "personal", privacy: .public)")
            throw VaultError.itemRecordUnavailable
        }

        // The revision the server last gave for this item. Without one Prizm cannot tell whether the
        // copy it edited is still the server's, and Vaultwarden skips its own check on a revision it
        // cannot parse, so the save would be a blind overwrite: refused before any key work. The
        // epoch is refused too, because it is what a missing date turns into once something falls
        // back to a default.
        guard let baseRevision = CipherMapper.parseRevisionDate(base.revisionDate),
              baseRevision.timeIntervalSince1970 > 0 else {
            logger.error("Save refused: stored record of \(draft.id, privacy: .public) has no readable revision")
            throw VaultError.itemRevisionUnavailable
        }

        // The edit must be based on the server copy Prizm holds now. A sync that replaced the stored
        // record while the sheet was open leaves the draft on an older one: saving it would overwrite
        // what the sync brought in. Equality, not order, so the check never depends on whose clock is
        // ahead. This is not the servers' check (whole seconds, a 1 or 2 second slack); edits made
        // within that slack of each other are not promised to be caught.
        guard CipherMapper.sameRevision(draft.revisionDate, baseRevision) else {
            logger.info("Save refused: item \(draft.id, privacy: .public) changed since it was loaded")
            throw VaultError.conflict
        }

        // Read once: a lock or a sync during the save cannot change the keys used for this request.
        let orgKeysSnapshot = await orgKeyCache.snapshot()
        let activeKeys = try encryptionKeys(organizationId: base.organizationId, vaultKeys: vaultKeys, orgKeys: orgKeysSnapshot)
        let profileId = try await requireProfileId()

        // The item's own key when it has one, else the active key (never the other way round, and
        // never a fallback). Failing here and at the key check below sends nothing and encrypts
        // nothing: the overlay runs only after both.
        let effectiveKeys: CryptoKeys
        do {
            effectiveKeys = try mapper.effectiveKeys(for: base, activeKeys: activeKeys)
            try mapper.verifyKey(effectiveKeys, against: base)
        } catch {
            logger.error("Save refused: no usable key for \(draft.id, privacy: .public)")
            throw VaultError.itemKeyUnavailable
        }

        let rawCipher: RawCipher
        do {
            rawCipher = try mapper.toRawCipher(draft, overlaying: base, effectiveKeys: effectiveKeys, encryptedFor: profileId)
        } catch CipherMapperError.storedValueUnreadable {
            logger.error("Save refused: a stored value of \(draft.id, privacy: .public) cannot be read with its key")
            throw VaultError.itemKeyUnavailable
        }

        // TODO: Queue encrypted rawCipher for offline persistence (deferred — requires WAL).
        // Only this call is mapped: /partial, the collections call and create carry no last-known
        // revision, so the same words in their answer are not a stale write. Nothing is retried and
        // the stored record keeps what it holds; the sheet's reload is the way forward.
        let updatedRaw: RawCipher
        do {
            updatedRaw = try await apiClient.updateCipher(id: draft.id, cipher: rawCipher)
        } catch let error as APIError where error.isOutOfDateRejection {
            logger.info("Save rejected: item \(draft.id, privacy: .public) is out of date")
            throw VaultError.conflict
        }
        // Security goal: no plaintext re-enters memory after lock. The keys above were captured
        // before the lock, so a response mapped with them would put the decrypted item back into the
        // emptied cache. The save throws instead of returning, so no success callback runs for it.
        // Checked after the request, after the collections request, and (with no suspension in
        // between) right before the map and the cache write.
        // Intentionally NOT done here: `deleteItem`, `restoreItem`, `updateAttachments` and
        // `sendPartial` only modify entries that are already cached, so they cannot put an item
        // back into an emptied cache.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Save finished after lock, dropped: \(draft.id, privacy: .public)")
            throw VaultError.vaultLocked
        }

        // Keep what the server answered, not what was sent. Refused after a lock by the store too.
        await storeRecord(updatedRaw, ifCurrent: storeGeneration)

        if draft.organizationId != nil {
            try await apiClient.updateCipherCollections(id: draft.id, collectionIds: draft.collectionIds)
        }

        // Last check before the first write to the item cache: everything below is synchronous.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Save finished after lock, dropped: \(draft.id, privacy: .public)")
            throw VaultError.vaultLocked
        }
        var (updatedItem, _) = try mapper.map(raw: updatedRaw, vaultKeys: vaultKeys, orgKeys: orgKeysSnapshot)

        // Patch collectionIds: PUT /api/ciphers/{id} returns pre-update collection state.
        if draft.organizationId != nil {
            updatedItem = updatedItem.with(collectionIds: draft.collectionIds)
        }

        if let idx = items.firstIndex(where: { $0.id == updatedItem.id }) {
            items[idx] = updatedItem
        } else {
            items.append(updatedItem)
        }
        buildIndexes()
        logger.info("Vault item updated: \(draft.id, privacy: .public)")
        return updatedItem
    }

    // MARK: - Create (write path)

    func create(_ draft: DraftVaultItem) async throws -> VaultItem {
        // First, before any await on the network: `clearVault()` bumps this token, so a lock that
        // lands while the request runs makes the store write and the cache write below refuse. A
        // token read at the write would always be current.
        let storeGeneration = recordStore.currentGeneration()

        let vaultKeys: CryptoKeys
        do {
            vaultKeys = try await crypto.currentKeys()
        } catch PrizmCryptoServiceError.vaultLocked {
            throw VaultError.vaultLocked
        }

        let orgKeysSnapshot = await orgKeyCache.snapshot()
        let encryptionKeys = try encryptionKeys(organizationId: draft.organizationId, vaultKeys: vaultKeys, orgKeys: orgKeysSnapshot)
        let profileId = try await requireProfileId()

        // An org create carries `encryptedFor` inside `cipher` (OrgCipherCreateRequest encodes the
        // RawCipher there); a personal create has it at the top level.
        let rawCipher = try mapper.toNewRawCipher(draft, encryptedWith: encryptionKeys, encryptedFor: profileId)

        let createdRaw: RawCipher
        if draft.organizationId != nil {
            createdRaw = try await apiClient.createOrgCipher(cipher: rawCipher)
        } else {
            createdRaw = try await apiClient.createCipher(cipher: rawCipher)
        }
        // Same security goal as in `update`: a create that finishes after lock throws and caches
        // nothing; the keys captured before the lock are never used to decrypt its answer.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Save finished after lock, dropped: \(createdRaw.id, privacy: .public)")
            throw VaultError.vaultLocked
        }
        await storeRecord(createdRaw, ifCurrent: storeGeneration)

        // Last check before the cache write: everything below is synchronous.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Save finished after lock, dropped: \(createdRaw.id, privacy: .public)")
            throw VaultError.vaultLocked
        }
        // Discard cipherKey — newly created items are picked up by the next sync.
        let (createdItem, _) = try mapper.map(raw: createdRaw, vaultKeys: vaultKeys, orgKeys: orgKeysSnapshot)
        items.append(createdItem)
        buildIndexes()
        logger.info("Vault item created: \(createdItem.id, privacy: .public)")
        return createdItem
    }

    // MARK: - Delete / Restore / Empty Trash

    /// Soft-deletes the active item with `id` by calling `PUT /ciphers/{id}/delete`.
    ///
    /// - Security goal: no vault key material is needed — only the cipher ID is sent.
    ///   The access token (held by `PrizmAPIClientImpl`) authorises the operation.
    /// - Bitwarden endpoint: `PUT /api/ciphers/{id}/delete` — moves the cipher to Trash.
    func deleteItem(id: String) async throws {
        guard items.contains(where: { $0.id == id }) else { return }
        try await apiClient.softDeleteCipher(id: id)
        // Looked up again: this actor is reentrant, so a lock or a sync can have emptied or
        // replaced `items` while the request ran, and an index taken before it would trap or hit
        // another item.
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            logger.info("Vault item soft-deleted on the server, no longer cached: \(id, privacy: .public)")
            return
        }
        let old = items[idx]
        items[idx] = old.with(isDeleted: true)
        buildIndexes()
        logger.info("Vault item soft-deleted: \(id, privacy: .public)")
    }

    /// Permanently deletes the trashed item with `id` by calling `DELETE /ciphers/{id}`.
    ///
    /// - Security goal: same as `deleteItem` — only the cipher ID is sent; no key material.
    /// - Bitwarden endpoint: `DELETE /api/ciphers/{id}` — permanently removes the cipher.
    func permanentDeleteItem(id: String) async throws {
        let storeGeneration = recordStore.currentGeneration()
        guard items.contains(where: { $0.id == id }) else { return }
        try await apiClient.permanentDeleteCipher(id: id)
        await removeRecords([id], ifCurrent: storeGeneration)
        // By id, not by an index taken before the request: this actor is reentrant, so a lock or a
        // sync can have emptied or replaced `items` meanwhile.
        items.removeAll { $0.id == id }
        buildIndexes()
        logger.info("Vault item permanently deleted: \(id, privacy: .public)")
    }

    /// Bulk permanent delete for Empty Trash, `DELETE /api/ciphers` in chunks of 500 (the official
    /// cloud's limit; harmless on self-hosted servers).
    ///
    /// Security goal: only items that are in Trash are ever sent, even if `ids` holds others; the
    /// servers do not check that themselves (fix-empty-trash, D1). The items of each chunk that
    /// succeeded leave the cache. A failing chunk does not stop the others: Vaultwarden aborts a
    /// whole request at its first refused id (in arbitrary order), so later chunks may still go
    /// through; the first failure is thrown at the end.
    @discardableResult
    func permanentDeleteItems(ids: [String]) async throws -> Int {
        let storeGeneration = recordStore.currentGeneration()
        let requested = Set(ids)
        let trashed = items.filter { $0.isDeleted && requested.contains($0.id) }.map(\.id)
        var deletedCount = 0
        var firstFailure: Error?
        for start in stride(from: 0, to: trashed.count, by: 500) {
            let chunk = Array(trashed[start..<min(start + 500, trashed.count)])
            do {
                try await apiClient.permanentDeleteCiphers(ids: chunk)
            } catch {
                if firstFailure == nil { firstFailure = error }
                continue
            }
            await removeRecords(chunk, ifCurrent: storeGeneration)
            let deleted = Set(chunk)
            items.removeAll { deleted.contains($0.id) }
            deletedCount += chunk.count
            buildIndexes()
        }
        logger.info("Empty Trash: \(deletedCount, privacy: .public) of \(trashed.count, privacy: .public) item(s) permanently deleted")
        if let firstFailure { throw PermanentDeleteError(deleted: deletedCount, underlying: firstFailure) }
        return deletedCount
    }

    /// Restores the trashed item with `id` by calling `PUT /api/ciphers/{id}/restore`.
    ///
    /// - Security goal: same as `deleteItem` — only the cipher ID is sent; no key material.
    func restoreItem(id: String) async throws {
        guard items.contains(where: { $0.id == id }) else { return }
        try await apiClient.restoreCipher(id: id)
        // Looked up again, as in `deleteItem`: the cache can have changed while the request ran.
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            logger.info("Vault item restored on the server, no longer cached: \(id, privacy: .public)")
            return
        }
        let old = items[idx]
        items[idx] = old.with(isDeleted: false)
        buildIndexes()
        logger.info("Vault item restored: \(id, privacy: .public)")
    }

    // MARK: - Attachment cache patch

    /// Replaces the `attachments` array for the item identified by `cipherId` in the
    /// in-memory store without triggering a full re-sync.
    func updateAttachments(_ attachments: [Attachment], for cipherId: String) async {
        guard let idx = items.firstIndex(where: { $0.id == cipherId }) else {
            logger.error("updateAttachments: cipher not found in cache — id=\(cipherId, privacy: .public)")
            return
        }
        let old = items[idx]
        items[idx] = old.with(attachments: attachments)
        buildIndexes()
        logger.info("Vault item attachments updated: cipher=\(cipherId, privacy: .public) count=\(attachments.count, privacy: .public)")
    }

    // MARK: - Folder CRUD

    func createFolder(name: String) async throws -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultError.decryptionFailed("empty folder name") }
        let encName = try await encryptFolderName(trimmed)
        let raw = try await apiClient.createFolder(encryptedName: encName)
        let folder = Folder(id: raw.id, name: trimmed)
        folderStore.append(folder)
        buildIndexes()
        logger.info("Folder created: \(raw.id, privacy: .public)")
        return folder
    }

    func renameFolder(id: String, name: String) async throws -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultError.decryptionFailed("empty folder name") }
        let encName = try await encryptFolderName(trimmed)
        _ = try await apiClient.updateFolder(id: id, encryptedName: encName)
        let folder = Folder(id: id, name: trimmed)
        if let idx = folderStore.firstIndex(where: { $0.id == id }) {
            folderStore[idx] = folder
        }
        buildIndexes()
        logger.info("Folder renamed: \(id, privacy: .public)")
        return folder
    }

    func deleteFolder(id: String) async throws {
        try await apiClient.deleteFolder(id: id)
        folderStore.removeAll { $0.id == id }
        // Unfolder items that were in this folder (server does this too).
        for i in items.indices where items[i].folderId == id {
            items[i] = items[i].with(folderId: nil)
        }
        buildIndexes()
        logger.info("Folder deleted: \(id, privacy: .public)")
    }

    // MARK: - Collection CRUD

    /// Creates a new collection within an organization.
    ///
    /// - Security goal: collection names are encrypted with the *org* symmetric key
    ///   (not the vault key) so that all members of the organization can decrypt them.
    ///   Reference: Bitwarden Security Whitepaper §4 — "Organization Key Wrapping".
    func createCollection(name: String, organizationId: String) async throws -> OrgCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultError.decryptionFailed("empty collection name") }
        // The creator is assigned with Manage, as the web vault preselects; without a member with
        // Manage the official server rejects the create, and the collection could drop out of the
        // creator's own sync (fix-collection-access-on-rename, D3).
        let membershipId = organizationStore.first(where: { $0.id == organizationId })?.membershipId
        let encName = try await encryptCollectionName(trimmed, organizationId: organizationId)
        let request: CollectionWriteRequest
        switch membershipId {
        case .known(let memberId):
            request = CollectionWriteRequest(
                name: encName, externalId: nil,
                users: [CollectionAccessSelection(id: memberId, readOnly: false, hidePasswords: false, manage: true)],
                groups: []
            )
        case .notSent:
            request = LegacyCollectionCreateWithoutMembership.request(encryptedName: encName)
        case .unreadable, nil:
            logger.error("Collection not created: no readable organizationUserId in the sync profile")
            throw VaultError.organizationMembershipUnreadable
        }
        let raw = try await apiClient.createCollection(organizationId: organizationId, request: request)
        let collection = OrgCollection(id: raw.id, organizationId: organizationId, name: trimmed)
        collectionStore.append(collection)
        buildIndexes()
        logger.info("Collection created: \(raw.id, privacy: .public)")
        return collection
    }

    /// Renames an existing collection, keeping its access settings. New name encrypted with the
    /// org key.
    ///
    /// Both servers replace a collection's members, groups and `externalId` with the ones in the
    /// rename request, so the request must carry the current ones: they are read first with
    /// `GET …/collections/{id}/details` and sent back unchanged, as the web vault does. If they
    /// can't be read, nothing is sent (fix-collection-access-on-rename, D1–D2). Not cached.
    func renameCollection(id: String, organizationId: String, name: String) async throws -> OrgCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultError.decryptionFailed("empty collection name") }
        let details: CollectionAccessDetailsResponse
        do {
            details = try await apiClient.getCollectionAccessDetails(organizationId: organizationId, id: id)
        } catch {
            // Status only: an HTTP error's description carries the response body.
            let status = (error as? APIError).flatMap { if case .httpError(let code, _) = $0 { code } else { nil } }
            logger.error("Collection not renamed: access settings not readable for \(id, privacy: .public) (HTTP \(status.map(String.init) ?? "n/a", privacy: .public))")
            throw VaultError.collectionAccessUnreadable
        }
        guard let users = details.users, let groups = details.groups else {
            logger.error("Collection not renamed: access settings incomplete for \(id, privacy: .public)")
            throw VaultError.collectionAccessUnreadable
        }
        let encName = try await encryptCollectionName(trimmed, organizationId: organizationId)
        let request = CollectionWriteRequest(name: encName, externalId: details.externalId, users: users, groups: groups)
        _ = try await apiClient.renameCollection(id: id, organizationId: organizationId, request: request)
        let collection = OrgCollection(id: id, organizationId: organizationId, name: trimmed)
        if let idx = collectionStore.firstIndex(where: { $0.id == id }) {
            collectionStore[idx] = collection
        }
        buildIndexes()
        logger.info("Collection renamed: \(id, privacy: .public)")
        return collection
    }

    /// Deletes a collection from an organization and removes it from the local cache.
    ///
    /// Items that were in the collection are NOT deleted — they remain in the vault
    /// with stale `collectionIds` entries that no longer match a known collection.
    func deleteCollection(id: String, organizationId: String) async throws {
        try await apiClient.deleteCollection(id: id, organizationId: organizationId)
        collectionStore.removeAll { $0.id == id }
        buildIndexes()
        logger.info("Collection deleted: \(id, privacy: .public)")
    }

    // MARK: - Move to folder

    func moveItemToFolder(itemId: String, folderId: String?) async throws {
        guard let old = items.first(where: { $0.id == itemId }) else { return }
        try await sendPartial(itemId: itemId, folderId: folderId, favorite: old.isFavorite)
        logger.info("Item moved to folder: \(itemId, privacy: .public)")
    }

    func moveItemsToFolder(itemIds: [String], folderId: String?) async throws {
        try await apiClient.moveCiphersToFolder(ids: itemIds, folderId: folderId)
        for i in items.indices where itemIds.contains(items[i].id) {
            items[i] = items[i].with(folderId: folderId)
        }
        buildIndexes()
        logger.info("Bulk move to folder: \(itemIds.count, privacy: .public) item(s)")
    }

    // MARK: - Favorite

    /// Sets the favorite state with `PUT /api/ciphers/{id}/partial`, sending the cached folder.
    ///
    /// Deliberately not the full cipher PUT the official clients use for editable items: the
    /// partial request carries no item data, so it cannot drop fields Prizm does not model, needs
    /// no key, and works on read-only org items (fix-favorite-and-folder-partial-updates, D1).
    func setFavorite(itemId: String, isFavorite: Bool) async throws -> VaultItem {
        guard let old = items.first(where: { $0.id == itemId }) else {
            throw VaultError.itemNotFound(itemId)
        }
        let updated = try await sendPartial(itemId: itemId, folderId: old.folderId, favorite: isFavorite)
        logger.info("Favorite set: \(itemId, privacy: .public)")
        // The server saved it; if a lock or sync removed the item from the cache meanwhile, report
        // the item as it now is on the server.
        return updated ?? old.with(isFavorite: isFavorite)
    }

    /// Sends `/partial` and, once the server confirms it, caches exactly the pair that was sent.
    ///
    /// - Each request carries both per-user fields, so the server keeps the last request's pair;
    ///   caching that pair keeps the cache equal to the server when a move and a star overlap.
    /// - Neither server bumps the cipher's revision on /partial, so the cached one stays (D3).
    /// - The item is looked up again after the request: this actor is reentrant, and a sync can
    ///   replace the cache meanwhile.
    /// - Throws `VaultError.partialUpdateNotSaved` when the response shows another state: Bitwarden's
    ///   Entity Framework backends answer 200 without saving (`CipherRepository.UpdatePartialAsync`).
    ///   A field missing from the response is not checked.
    /// - Returns: the updated cached item, or nil if it is no longer cached.
    @discardableResult
    private func sendPartial(itemId: String, folderId: String?, favorite: Bool) async throws -> VaultItem? {
        let response = try await apiClient.updateCipherPartial(id: itemId, folderId: folderId, favorite: favorite)
        if let saved = response.favorite, saved != favorite {
            logger.error("Partial update not saved by the server (favorite): \(itemId, privacy: .public)")
            throw VaultError.partialUpdateNotSaved
        }
        if case .some(let savedFolder) = response.folderId, savedFolder?.lowercased() != folderId?.lowercased() {
            logger.error("Partial update not saved by the server (folder): \(itemId, privacy: .public)")
            throw VaultError.partialUpdateNotSaved
        }
        guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return nil }
        items[idx] = items[idx].with(folderId: folderId).with(isFavorite: favorite)
        buildIndexes()
        return items[idx]
    }

    // MARK: - Private helpers

    /// The key an item's own key (or, without one, its fields) is encrypted with: its organization's
    /// key for an org item, the vault key otherwise. On update, `organizationId` is the stored
    /// record's, not the draft's; on create it is the draft's.
    ///
    /// Security goal: an org item must only ever be encrypted with its organization key.
    /// Encrypting it with the user's key makes it unreadable for every other member and for this
    /// user's next sync, while the server stores it as is. Mirrors the SDK's
    /// `Cipher::key_identifier` (`bitwarden-vault/src/cipher/cipher.rs`), which has no fallback.
    /// Intentionally NOT done: falling back to the vault key when the org key is missing (before
    /// fix-org-key-required-on-write it did, for example while a sync rebuilt the key cache), and
    /// using the attachment key service, whose cache miss returns the vault key.
    private func encryptionKeys(organizationId: String?, vaultKeys: CryptoKeys,
                                orgKeys: [String: CryptoKeys]) throws -> CryptoKeys {
        guard let orgId = organizationId else { return vaultKeys }
        guard let orgKey = orgKeys[orgId] else {
            logger.error("No key for org \(orgId.prefix(8), privacy: .public)…; save refused")
            throw VaultError.organizationKeyUnavailable
        }
        return orgKey
    }

    /// Stores the server's answer for one item. A refusal means the vault was cleared since the
    /// operation started; the record is dropped and only the item id is logged.
    private func storeRecord(_ cipher: RawCipher, ifCurrent token: RawCipherStore.Generation) async {
        let stored = await recordStore.upsert(cipher, ifCurrent: token)
        if !stored {
            logger.info("Stored record not updated for \(cipher.id, privacy: .public): the vault was cleared during the save")
        }
    }

    /// Removes the records of permanently deleted items; a refusal is logged by count, not by id.
    private func removeRecords(_ ids: [String], ifCurrent token: RawCipherStore.Generation) async {
        let removed = await recordStore.remove(ids: ids, ifCurrent: token)
        if !removed {
            logger.info("Stored records not removed for \(ids.count, privacy: .public) item(s): the vault was cleared during the delete")
        }
    }

    /// The id for `encryptedFor`, or `VaultError.profileIdUnavailable` before the first sync of the
    /// session and after lock or sign-out.
    ///
    /// Intentionally NOT done: sending the save without it. Vaultwarden 1.37.4 rejects such a body
    /// (HTTP 422), and a body built for another account must never leave the device, so a missing
    /// id fails the save before any request.
    private func requireProfileId() async throws -> String {
        guard let profileId = await profileIds.current() else {
            logger.error("Save refused: no profile id from a sync in this session")
            throw VaultError.profileIdUnavailable
        }
        return profileId
    }

    private func sorted(_ input: [VaultItem]) -> [VaultItem] {
        input.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Encrypts a plaintext folder name as a type-2 EncString using the current vault keys.
    ///
    /// - Security: AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC) with a fresh random IV.
    ///   Same algorithm as cipher field encryption in `CipherMapper.encryptString`.
    private func encryptFolderName(_ name: String) async throws -> String {
        let keys: CryptoKeys
        do {
            keys = try await crypto.currentKeys()
        } catch PrizmCryptoServiceError.vaultLocked {
            throw VaultError.vaultLocked
        }
        guard let data = name.data(using: .utf8) else {
            throw VaultError.decryptionFailed("utf8-encode")
        }
        return try EncString.encrypt(data: data, keys: keys).toString()
    }

    /// Encrypts a plaintext collection name using the organization's symmetric key.
    ///
    /// - Security goal: collection names are org-key-encrypted so any org member
    ///   can read them. The vault key is NOT used — it is per-user, not per-org.
    ///   Algorithm: EncString type-2 (AES-256-CBC + HMAC-SHA256).
    private func encryptCollectionName(_ name: String, organizationId: String) async throws -> String {
        let orgSnapshot = await orgKeyCache.snapshot()
        guard let orgKey = orgSnapshot[organizationId] else {
            throw VaultError.decryptionFailed("org key not found for org: \(organizationId)")
        }
        guard let data = name.data(using: .utf8) else {
            throw VaultError.decryptionFailed("utf8-encode")
        }
        return try EncString.encrypt(data: data, keys: orgKey).toString()
    }
}

// MARK: - ItemContent search / type matching

nonisolated private extension ItemContent {
    func matchesItemType(_ type: ItemType) -> Bool {
        switch (self, type) {
        case (.login,      .login):      return true
        case (.card,       .card):       return true
        case (.identity,   .identity):   return true
        case (.secureNote, .secureNote): return true
        case (.sshKey,     .sshKey):     return true
        default:                         return false
        }
    }
}

nonisolated private extension VaultItem {
    /// Case-insensitive substring search across type-specific fields (FR-012).
    func matchesSearch(query: String) -> Bool {
        if name.localizedCaseInsensitiveContains(query) { return true }
        switch content {
        case .login(let l):
            return (l.username?.localizedCaseInsensitiveContains(query) == true) ||
                   l.uris.contains { $0.uri.localizedCaseInsensitiveContains(query) }
        case .card(let c):
            return c.cardholderName?.localizedCaseInsensitiveContains(query) == true
        case .identity(let i):
            return (i.email?.localizedCaseInsensitiveContains(query) == true) ||
                   (i.company?.localizedCaseInsensitiveContains(query) == true)
        case .secureNote, .sshKey:
            return false
        }
    }
}
