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

    // MARK: - Write queue

    /// The last queued write of each item id; see `serialised(_:_:)`. An entry exists only while a
    /// write to that item is queued or running.
    private var writeTails: [String: Task<Void, Never>] = [:]

    /// How many item ids have a write queued or running. For tests: it must be 0 once all writes
    /// have finished.
    var queuedWriteCount: Int { writeTails.count }

    /// How many fetches a bulk move's background refresh keeps in flight: a drag of many items must
    /// not open hundreds of requests at once.
    nonisolated private static let bulkRefreshConcurrency = 4

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

    /// Security goal: a sync result must not put decrypted items back into a vault that was
    /// cleared while the sync ran. The check is the first statement and synchronous, so nothing is
    /// changed when the token is stale or was not handed out by the record store.
    func populate(items: [VaultItem], folders: [Folder], organizations: [Organization],
                  collections: [OrgCollection], syncedAt: Date, session: VaultSessionToken) async {
        guard recordStore.isCurrent(session) else {
            logger.info("Sync result dropped: the vault was cleared while it ran")
            return
        }
        self.items             = items
        self.folderStore       = folders
        self.organizationStore = organizations
        self.collectionStore   = collections
        self.lastSyncedAt      = syncedAt
        buildIndexes()
        logger.info("Vault populated: \(items.count) item(s), \(folders.count) folder(s), \(organizations.count) org(s), \(collections.count) collection(s)")
    }

    #if DEBUG
    /// The test seam of `VaultRepository`: populates under the token current now, so it fences
    /// nothing; compiled out of Release builds.
    func populate(items: [VaultItem], folders: [Folder], organizations: [Organization],
                  collections: [OrgCollection], syncedAt: Date) async {
        await populate(items: items, folders: folders, organizations: organizations,
                       collections: collections, syncedAt: syncedAt, session: recordStore.currentGeneration())
    }
    #endif

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
    /// - Organization items: when the draft's collection set differs from the stored record's, the
    ///   collections are sent afterwards with `PUT /collections_v2`, which changes the revision on the
    ///   official server. The record stored for the item, and the revision of the item returned, are
    ///   then the collections answer's (or a fetch when it holds no cipher), never the item PUT's. The
    ///   PUT answer still supplies everything else and reports the collections from before the
    ///   update, so the draft's collections are patched in. An unchanged set sends no collections
    ///   request (fix-collection-assignment, D5).
    ///
    /// - Partial save: when the item PUT succeeded and the collections request failed, the saved
    ///   item is kept (stored, cached with the collections the PUT answer reports, refreshed with a
    ///   fetch) and `VaultError.collectionChangeNotSaved` is thrown. A retry is the same draft with
    ///   its base moved to the cached revision, sent as a full PUT again: the item is rewritten with
    ///   identical values, which is harmless, and the collections request then runs once more.
    ///   Intentionally NOT done: a collections-only retry, which would be a second send path for one
    ///   field.
    ///
    /// - Queue: saves of one item run one after another (see `serialised(_:_:)`), so a save waits
    ///   for an earlier write to the same item and then runs every check above against the record
    ///   that write stored.
    ///
    /// - Throws: `VaultError.vaultLocked`, `itemNotEditable`, `itemRecordUnavailable`,
    ///   `itemRevisionUnavailable`, `organizationKeyUnavailable`, `profileIdUnavailable` or
    ///   `itemKeyUnavailable` as above.
    /// - Throws: `VaultError.conflict` from the pre-check, and when the server rejects the PUT as out
    ///   of date (HTTP 400, `APIError.isOutOfDateRejection`). The server copy is untouched and
    ///   nothing is retried.
    /// - Throws: `VaultError.vaultLocked` also when the vault was cleared while the request ran: the
    ///   answer is then dropped unread (nothing decrypted, stored or cached).
    /// - Throws: `VaultError.savedButAccessLost` when both were saved and the server reports that the
    ///   user can no longer see the item; it is removed from the cache and the store.
    /// - Throws: `VaultError.collectionChangeNotSaved` when the item was saved and its collection
    ///   update failed, for any reason (an "out of date" answer to `/collections_v2` included: it is not
    ///   the item PUT, so it is no conflict).
    /// - Throws: `APIError` on any other network or HTTP failure.
    /// - Throws: `CipherMapperError` if the server's answer to the PUT cannot be mapped. Nothing is
    ///   stored or cached then, and the collections request is not sent.
    func update(_ draft: DraftVaultItem) async throws -> VaultItem {
        // First, before the save waits for its turn and before any await: `clearVault()` bumps this
        // token, so a lock that lands while the save waits or while its request runs makes it
        // refuse. A token read when the save finally runs would always be current. Synchronous, so
        // no suspension sits between starting the save and holding the token.
        let storeGeneration = recordStore.currentGeneration()
        return try await serialised([draft.id]) { [self] in
            try await performUpdate(draft, storeGeneration: storeGeneration)
        }
    }

    /// The body of `update`, run by the item's write queue: never call a queued public method from
    /// here (the queue would wait for itself).
    private func performUpdate(_ draft: DraftVaultItem, storeGeneration: RawCipherStore.Generation) async throws -> VaultItem {
        // TODO: Require biometric re-auth before encrypting and sending — deferred pending
        // SecureEnclave entitlement approval.

        // A save that waited in the queue across a lock sends nothing: its keys and its draft belong
        // to the session that ended.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Save dropped before sending, the vault was cleared while it waited: \(draft.id, privacy: .public)")
            throw VaultError.vaultLocked
        }

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
                let updated = try await sendPartial(itemId: draft.id, folderId: draft.folderId, favorite: draft.isFavorite,
                                                    storeGeneration: storeGeneration)
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

        // The last check before the request, with no suspension between it and the send: a lock that
        // landed in the awaits above (keys, stored record, organization keys, profile id) must not
        // let this save leave the device. The result of one that is sent after all is dropped below.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Save dropped before sending, the vault was cleared while it prepared: \(draft.id, privacy: .public)")
            throw VaultError.vaultLocked
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
        // Checked after the request (with no suspension before the map), after the collections
        // request, and (with no suspension in between) right before each cache write. The mapped
        // item stays in this function until the cache write; a lock meanwhile makes those checks
        // throw, and it is dropped with the function.
        // Intentionally NOT done here: `deleteItem`, `restoreItem`, `updateAttachments` and
        // `sendPartial` only modify entries that are already cached, so they cannot put an item
        // back into an emptied cache.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Save finished after lock, dropped: \(draft.id, privacy: .public)")
            throw VaultError.vaultLocked
        }

        // Mapped before anything is stored. If the answer cannot be read, the save fails with the
        // mapping error and neither the stored record nor the cache changes: an unreadable answer
        // in the store next to the old cached item would leave the two on different revisions,
        // and a retry from the still-open sheet would be refused here as a change made elsewhere,
        // although the change was this save. The retry goes to the server instead, which decides.
        var (updatedItem, _) = try mapper.map(raw: updatedRaw, vaultKeys: vaultKeys, orgKeys: orgKeysSnapshot)

        // Keep what the server answered, not what was sent. Refused after a lock by the store too.
        await storeRecord(updatedRaw, ifCurrent: storeGeneration)

        // Only a change is sent (fix-collection-assignment, D5): the stored record holds the
        // collections the server has, and an unchanged set would only cost a request, an event in
        // the organization's log, and on Vaultwarden a refusal for members of read-only collections.
        // The user's change applied to the collections the server holds now (D2a): a sync while
        // the sheet was open may have brought in another member's change, which Vaultwarden makes
        // without a new revision.
        let savedCollectionIds = draft.originalCollectionIds.map {
            CollectionAssignment.rebased(stored: base.collectionIds, original: $0, edited: draft.collectionIds)
        } ?? draft.collectionIds
        let collectionsChanged = draft.organizationId != nil && Set(savedCollectionIds) != Set(base.collectionIds)

        // The collections answer is the item's newest record (the official server changes the
        // revision on this call); nil without a collection change and for an answer without a cipher.
        var collectionsAnswer: RawCipher?
        if collectionsChanged {
            let result: CipherCollectionsResult
            do {
                result = try await apiClient.updateCipherCollections(id: draft.id, collectionIds: requestCollectionIds(savedCollectionIds))
            } catch {
                guard recordStore.isCurrent(storeGeneration) else {
                    logger.info("Save finished after lock, dropped: \(draft.id, privacy: .public)")
                    throw VaultError.vaultLocked
                }
                // The item PUT went through and is the server's copy now: keep it, with the
                // collections its answer reports, because the collection change did not happen. Then
                // learn the revision the server holds, so a retry is checked against it and is not
                // mistaken for a conflict with this very save.
                cacheItem(updatedItem)
                await refreshRecord(id: draft.id, from: nil, token: storeGeneration)
                logger.error("Collection update failed after the item was saved: \(draft.id, privacy: .public): \(ErrorLog.describe(error), privacy: .public)")
                guard recordStore.isCurrent(storeGeneration) else { throw VaultError.vaultLocked }
                throw VaultError.collectionChangeNotSaved
            }
            if result.unavailable {
                // Both changes are saved, and the user can no longer see the item: it leaves the
                // cache and the store, as after a sync that no longer lists it.
                guard recordStore.isCurrent(storeGeneration) else {
                    logger.info("Save finished after lock, dropped: \(draft.id, privacy: .public)")
                    throw VaultError.vaultLocked
                }
                items.removeAll { $0.id == draft.id }
                buildIndexes()
                await removeRecords([draft.id], ifCurrent: storeGeneration)
                logger.info("Item saved; its collection change ended the user's access: \(draft.id, privacy: .public)")
                throw VaultError.savedButAccessLost
            }
            collectionsAnswer = result.cipher
        }

        // Last check before the first write to the item cache: everything below is synchronous.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Save finished after lock, dropped: \(draft.id, privacy: .public)")
            throw VaultError.vaultLocked
        }

        // Patch collectionIds: PUT /api/ciphers/{id} returns pre-update collection state.
        if collectionsChanged {
            updatedItem = updatedItem.with(collectionIds: savedCollectionIds)
        }

        cacheItem(updatedItem)
        if collectionsChanged {
            // Stores the collections answer (or a fetch) and moves the cached revision to it.
            // Without a collection change the item keeps what the PUT answered.
            await refreshRecord(id: draft.id, from: collectionsAnswer, token: storeGeneration)
            guard recordStore.isCurrent(storeGeneration) else {
                logger.info("Save finished after lock, dropped: \(draft.id, privacy: .public)")
                throw VaultError.vaultLocked
            }
            updatedItem = items.first(where: { $0.id == updatedItem.id }) ?? updatedItem
        }
        logger.info("Vault item updated: \(draft.id, privacy: .public)")
        return updatedItem
    }

    /// The ids of `ids` to send in the collections request, in order: all but the collections the
    /// last sync lists as read-only for the user. Vaultwarden 1.37.4 refuses the whole request when
    /// a read-only collection is in it (even an unchanged one) and keeps a read-only assignment that
    /// is left out; the official server changes only writable assignments (live rig 2026-10-30).
    /// Unknown ids (a collection whose name did not decrypt) are sent: one may be writable, and
    /// leaving it out would make the server remove it (fix-collection-assignment, design D2).
    private func requestCollectionIds(_ ids: [String]) -> [String] {
        let readOnly = Set(collectionStore.filter(\.readOnly).map(\.id))
        return ids.filter { !readOnly.contains($0) }
    }

    /// Replaces the cached item with the same id, or appends it, and rebuilds the indexes. The
    /// caller has just checked the store token, with no suspension in between.
    private func cacheItem(_ item: VaultItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.append(item)
        }
        buildIndexes()
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

        // Vaultwarden hides an SSH key without all three values; the mapper then checks that the
        // fingerprint is the one of the public key (ssh-key-import-and-generation, D5).
        if case .sshKey(let ssh) = draft.content,
           ![ssh.privateKey, ssh.publicKey, ssh.keyFingerprint].allSatisfy({ $0?.isEmpty == false }) {
            logger.error("Create refused: SSH key without all three key values")
            throw CipherMapperError.sshKeyIncomplete
        }

        let orgKeysSnapshot = await orgKeyCache.snapshot()
        let encryptionKeys = try encryptionKeys(organizationId: draft.organizationId, vaultKeys: vaultKeys, orgKeys: orgKeysSnapshot)
        let profileId = try await requireProfileId()

        // An org create carries `encryptedFor` inside `cipher` (OrgCipherCreateRequest encodes the
        // RawCipher there); a personal create has it at the top level.
        let rawCipher = try mapper.toNewRawCipher(draft, encryptedWith: encryptionKeys, encryptedFor: profileId)

        // The last check before the request, with no suspension between it and the send (same as in
        // `performUpdate`): a lock that landed in the awaits above must not let the create go out.
        guard recordStore.isCurrent(storeGeneration) else {
            logger.info("Create dropped before sending, the vault was cleared while it prepared")
            throw VaultError.vaultLocked
        }

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
    ///
    /// - Revision: the server gives the item a new revision, and the answer carries none, so the
    ///   item is fetched afterwards and its record and cached revision are refreshed
    ///   (`refreshRecord`); a failed fetch does not fail the delete.
    func deleteItem(id: String) async throws {
        // Before the delete waits for its turn, as in `update`: a lock while it waits must stop the
        // refresh from storing a record of the next session.
        let storeGeneration = recordStore.currentGeneration()
        try await serialised([id]) { [self] in
            try await performDeleteItem(id: id, storeGeneration: storeGeneration)
        }
    }

    private func performDeleteItem(id: String, storeGeneration: RawCipherStore.Generation) async throws {
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
        await refreshRecord(id: id, from: nil, token: storeGeneration)
    }

    /// Permanently deletes the trashed item with `id` by calling `DELETE /ciphers/{id}`.
    ///
    /// - Security goal: same as `deleteItem` — only the cipher ID is sent; no key material.
    /// - Bitwarden endpoint: `DELETE /api/ciphers/{id}` — permanently removes the cipher.
    func permanentDeleteItem(id: String) async throws {
        // Before the write waits for its turn, as in `update`: a lock while it waits must stop it
        // from removing a record of the next session.
        let storeGeneration = recordStore.currentGeneration()
        try await serialised([id]) { [self] in
            try await performPermanentDeleteItem(id: id, storeGeneration: storeGeneration)
        }
    }

    private func performPermanentDeleteItem(id: String, storeGeneration: RawCipherStore.Generation) async throws {
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
        // Queued behind the writes of every item it may send, those in Trash now. Which items are
        // in Trash is decided again when its turn comes.
        let requested = Set(ids)
        let queuedIds = items.filter { $0.isDeleted && requested.contains($0.id) }.map(\.id)
        return try await serialised(queuedIds) { [self] in
            try await performPermanentDeleteItems(ids: ids, storeGeneration: storeGeneration)
        }
    }

    private func performPermanentDeleteItems(ids: [String], storeGeneration: RawCipherStore.Generation) async throws -> Int {
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
    ///
    /// - Revision: Vaultwarden 1.37.4 answers with the restored cipher (tested) and the official
    ///   server does too (source-reviewed, not tested); its record and revision replace the stored
    ///   and cached ones (`refreshRecord`), or the item is fetched when the answer holds no usable
    ///   cipher.
    func restoreItem(id: String) async throws {
        let storeGeneration = recordStore.currentGeneration()
        try await serialised([id]) { [self] in
            try await performRestoreItem(id: id, storeGeneration: storeGeneration)
        }
    }

    private func performRestoreItem(id: String, storeGeneration: RawCipherStore.Generation) async throws {
        guard items.contains(where: { $0.id == id }) else { return }
        let restored = try await apiClient.restoreCipher(id: id)
        // Looked up again, as in `deleteItem`: the cache can have changed while the request ran.
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            logger.info("Vault item restored on the server, no longer cached: \(id, privacy: .public)")
            return
        }
        let old = items[idx]
        items[idx] = old.with(isDeleted: false)
        buildIndexes()
        logger.info("Vault item restored: \(id, privacy: .public)")
        await refreshRecord(id: id, from: restored, token: storeGeneration)
    }

    // MARK: - Attachment cache patch

    /// Replaces the `attachments` array for the item identified by `cipherId` in the
    /// in-memory store without triggering a full re-sync, then refreshes the item's stored record
    /// and cached revision (`refreshRecord`): the official server changes the revision on every
    /// attachment change, and none of the attachment requests answers with the cipher.
    func updateAttachments(_ attachments: [Attachment], for cipherId: String) async {
        let storeGeneration = recordStore.currentGeneration()
        // Non-throwing for its caller: the queue itself cannot fail, so an error here is not
        // expected; it is logged and dropped.
        do {
            try await serialised([cipherId]) { [self] in
                await performUpdateAttachments(attachments, for: cipherId, storeGeneration: storeGeneration)
            }
        } catch {
            logger.error("updateAttachments: queued write failed — id=\(cipherId, privacy: .public) \(ErrorLog.describe(error), privacy: .public)")
        }
    }

    private func performUpdateAttachments(_ attachments: [Attachment], for cipherId: String,
                                          storeGeneration: RawCipherStore.Generation) async {
        guard let idx = items.firstIndex(where: { $0.id == cipherId }) else {
            logger.error("updateAttachments: cipher not found in cache — id=\(cipherId, privacy: .public)")
            return
        }
        let old = items[idx]
        items[idx] = old.with(attachments: attachments)
        buildIndexes()
        logger.info("Vault item attachments updated: cipher=\(cipherId, privacy: .public) count=\(attachments.count, privacy: .public)")
        await refreshRecord(id: cipherId, from: nil, token: storeGeneration)
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
        let storeGeneration = recordStore.currentGeneration()
        try await serialised([itemId]) { [self] in
            try await performMoveItemToFolder(itemId: itemId, folderId: folderId, storeGeneration: storeGeneration)
        }
    }

    private func performMoveItemToFolder(itemId: String, folderId: String?,
                                         storeGeneration: RawCipherStore.Generation) async throws {
        guard let old = items.first(where: { $0.id == itemId }) else { return }
        try await sendPartial(itemId: itemId, folderId: folderId, favorite: old.isFavorite,
                              storeGeneration: storeGeneration)
        logger.info("Item moved to folder: \(itemId, privacy: .public)")
    }

    /// Waits for the running writes of every item in `itemIds` and then moves them in one request;
    /// it never fails because one of them is being written.
    ///
    /// Returns once the move request succeeded and the cache is patched. Each moved item's record
    /// and revision are then refreshed in the background (one fetch per item, at most
    /// `bulkRefreshConcurrency` at a time) while the item stays queued, so a later write to a moved
    /// item runs after that item's fetch, and only that one's. A failed fetch is only logged.
    func moveItemsToFolder(itemIds: [String], folderId: String?) async throws {
        let storeGeneration = recordStore.currentGeneration()
        try await serialised(itemIds, withTrailingTasks: { [self] in
            try await performMoveItemsToFolder(itemIds: itemIds, folderId: folderId, storeGeneration: storeGeneration)
        })
    }

    /// Returns the background refresh of each moved item as that item's trailing task in the queue.
    private func performMoveItemsToFolder(
        itemIds: [String], folderId: String?, storeGeneration: RawCipherStore.Generation
    ) async throws -> (result: Void, trailing: [String: Task<Void, Never>]) {
        try await apiClient.moveCiphersToFolder(ids: itemIds, folderId: folderId)
        for i in items.indices where itemIds.contains(items[i].id) {
            items[i] = items[i].with(folderId: folderId)
        }
        buildIndexes()
        logger.info("Bulk move to folder: \(itemIds.count, privacy: .public) item(s)")
        // Started here, inside the queued body, so the fetches begin at once; `serialised` keeps
        // each task as the queue tail of its own item. Duplicate ids are fetched once.
        var seen = Set<String>()
        let unique = itemIds.filter { seen.insert($0).inserted }
        return ((), startRefreshes(of: unique, token: storeGeneration))
    }

    // MARK: - Favorite

    /// Sets the favorite state with `PUT /api/ciphers/{id}/partial`, sending the cached folder.
    ///
    /// Deliberately not the full cipher PUT the official clients use for editable items: the
    /// partial request carries no item data, so it cannot drop fields Prizm does not model, needs
    /// no key, and works on read-only org items (fix-favorite-and-folder-partial-updates, D1).
    func setFavorite(itemId: String, isFavorite: Bool) async throws -> VaultItem {
        let storeGeneration = recordStore.currentGeneration()
        return try await serialised([itemId]) { [self] in
            try await performSetFavorite(itemId: itemId, isFavorite: isFavorite, storeGeneration: storeGeneration)
        }
    }

    private func performSetFavorite(itemId: String, isFavorite: Bool,
                                    storeGeneration: RawCipherStore.Generation) async throws -> VaultItem {
        guard let old = items.first(where: { $0.id == itemId }) else {
            throw VaultError.itemNotFound(itemId)
        }
        let updated = try await sendPartial(itemId: itemId, folderId: old.folderId, favorite: isFavorite,
                                            storeGeneration: storeGeneration)
        logger.info("Favorite set: \(itemId, privacy: .public)")
        // The server saved it; if a lock or sync removed the item from the cache meanwhile, report
        // the item as it now is on the server.
        return updated ?? old.with(isFavorite: isFavorite)
    }

    /// Sends `/partial` and, once the server confirms it, caches exactly the pair that was sent.
    ///
    /// - Each request carries both per-user fields, so the server keeps the last request's pair;
    ///   caching that pair keeps the cache equal to the server when a move and a star overlap.
    /// - Vaultwarden 1.37.4 does not bump the cipher's revision on /partial (tested) and the official
    ///   server does not either (source-reviewed, not tested), but the answer carries no cipher
    ///   either, so the item is fetched afterwards like after every own operation
    ///   (`refreshRecord`); the item returned is the cached one after that refresh.
    /// - The item is looked up again after the request: this actor is reentrant, and a sync can
    ///   replace the cache meanwhile.
    /// - Throws `VaultError.partialUpdateNotSaved` when the response shows another state: Bitwarden's
    ///   Entity Framework backends answer 200 without saving (`CipherRepository.UpdatePartialAsync`).
    ///   A field missing from the response is not checked.
    /// - Returns: the updated cached item, or nil if it is no longer cached.
    @discardableResult
    private func sendPartial(itemId: String, folderId: String?, favorite: Bool,
                             storeGeneration: RawCipherStore.Generation) async throws -> VaultItem? {
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
        await refreshRecord(id: itemId, from: nil, token: storeGeneration)
        // Looked up once more: the fetch suspended this actor, and a lock or a sync can have
        // changed the cache meanwhile.
        return items.first(where: { $0.id == itemId })
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

    /// Takes the server's current record of one item after an operation of Prizm's own, stores it,
    /// and moves the cached item's revision to it when that is safe, so the next edit starts from
    /// the revision the server holds. `known` is the operation's answer when it carried the cipher;
    /// otherwise the item is fetched.
    ///
    /// Runs whether or not the server changed the revision: Vaultwarden bumps it on soft delete and
    /// restore only, the official server also on attachments and collection changes, and one extra
    /// fetch costs less than a wrong guess about either.
    ///
    /// - The revision is moved only when nothing the user sees has changed. The cached item was
    ///   built from the record stored before the operation. If the fetched record's item content
    ///   (everything but `RecordContent.ignoredMembers`) differs from that record's, another client
    ///   changed the item in between, and the cached copy is out of date. Moving its revision on
    ///   would make a later save look current and overwrite that change, so the cached revision
    ///   stays, the next save fails the local pre-check with `VaultError.conflict`, and a reload
    ///   resolves it. The same holds when the cached revision was already behind the stored record's:
    ///   a conflict an earlier refresh left is not repaired by a later one. The check compares
    ///   ciphertext only; nothing is decrypted.
    ///
    /// - Security goal: nothing decrypted is created or kept by a refresh. It never maps or decrypts
    ///   the record (no key is read); only the ciphertext record in the store and the cached item's
    ///   revision date change, and a record that no key can read is stored as received. Both writes
    ///   are refused after a lock: the token the operation read at its start is checked before the
    ///   request, after it, and after the store write.
    /// - Not queued: called only from inside the queued body of the operation that caused it, so it
    ///   runs before any later write to the same item. It must never call a queued public method
    ///   (the queue would wait for itself).
    /// - A failed fetch is logged (item id and `ErrorLog.describe` only) and otherwise ignored: the
    ///   operation already succeeded on the server, the stored record and cached revision stay as
    ///   they were, and the worst case is one conflict on a later edit that a reload resolves. An
    ///   answer without a readable revision is treated the same way and never stored.
    /// - Intentionally NOT done: a fetch that was started before a sync and answers after it can
    ///   store an older record than the sync's, which costs one conflict and a reload. Comparing
    ///   revisions to prevent that would add a rule for a narrow window.
    private func refreshRecord(id: String, from known: RawCipher?, token: RawCipherStore.Generation) async {
        guard recordStore.isCurrent(token) else { return }
        let fresh: RawCipher
        if let known {
            fresh = known
        } else {
            do {
                fresh = try await apiClient.getCipher(id: id)
            } catch {
                logger.error("Revision refresh failed for \(id, privacy: .public): \(ErrorLog.describe(error), privacy: .public)")
                return
            }
        }
        // The store is keyed by the record's own id and the cached items by the id the sync
        // delivered: an answer for another item must not replace this one's record, and an answer
        // that spells the id differently (a case change) would open a second entry the next save
        // never reads, so the ids are compared exactly.
        guard fresh.id == id else {
            logger.error("Revision refresh ignored: the answer for \(id, privacy: .public) names another item")
            return
        }
        // Checked before the store write: an answer without a readable revision (the epoch is what a
        // missing one turns into) would replace a good record with one the next save refuses, while
        // the cached revision stayed behind. The old record stays, as after a failed fetch.
        guard let revision = CipherMapper.parseRevisionDate(fresh.revisionDate),
              revision.timeIntervalSince1970 > 0 else {
            logger.error("Revision refresh ignored: the answer for \(id, privacy: .public) has no readable revision")
            return
        }
        // The record the cached item was built from, read before it is replaced below.
        let before = await recordStore.record(for: id)
        guard recordStore.isCurrent(token) else {
            logger.info("Revision refresh dropped, the vault was cleared while it ran: \(id, privacy: .public)")
            return
        }
        await storeRecord(fresh, ifCurrent: token)
        // Checked again after the store await, and with no suspension between the check and the
        // write: a lock that landed during the await must not get a cached item back.
        guard recordStore.isCurrent(token),
              let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard let before,
              let beforeRevision = CipherMapper.parseRevisionDate(before.revisionDate),
              CipherMapper.sameRevision(items[idx].revisionDate, beforeRevision),
              RecordContent.isSame(before, fresh) else {
            logger.info("Revision refresh found the item changed elsewhere, cached revision kept: \(id, privacy: .public)")
            return
        }
        items[idx] = items[idx].with(revisionDate: revision)
        buildIndexes()
    }

    /// Starts one refresh task per id, with at most `bulkRefreshConcurrency` fetches in flight, and
    /// returns the tasks by id: a finished fetch makes room for the next waiting one. Each task
    /// ends when its own item's refresh has ended, which is what the item's queue tail waits for,
    /// so a later write to one moved item never waits for the fetches of the others. A failed
    /// fetch is logged by `refreshRecord` and does not stop the others.
    private func startRefreshes(of ids: [String], token: RawCipherStore.Generation) -> [String: Task<Void, Never>] {
        let slots = FetchSlots(limit: Self.bulkRefreshConcurrency)
        var tasks: [String: Task<Void, Never>] = [:]
        for id in ids {
            tasks[id] = Task { [self] in
                await slots.acquire()
                await refreshRecord(id: id, from: nil, token: token)
                await slots.release()
            }
        }
        let all = Array(tasks.values)
        Task { [logger] in
            for task in all { await task.value }
            logger.info("Revision refresh after the bulk move ended: \(ids.count, privacy: .public) item(s)")
        }
        return tasks
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

    /// Runs `operation` after every earlier write to any of `ids` has finished, and before any later
    /// one starts. Writes to other ids are not delayed. A bulk write passes all its ids and waits for
    /// each of them.
    ///
    /// Why: this actor is reentrant, so two writes to one item interleave between their awaits. The
    /// second would then read a stored record the first is about to replace and send, or cache, a
    /// result built on the older one. In the queue the second write starts from the record the
    /// first one stored, so its revision check sees the first write's revision.
    ///
    /// How: each call registers its own tail task for every id before anything is awaited (this
    /// method runs synchronously up to its first suspension, so no other write can slip in between
    /// reading the old tails and registering the new one), then waits for the tails it replaced.
    /// A tail removes itself only while it is still the registered one, so a later write's tail is
    /// never removed by an earlier one.
    ///
    /// - A write never fails because another one is running; it waits.
    /// - `operation` must call private unqueued helpers only. A queued public method called from
    ///   inside it would wait for its own tail and never return.
    /// - The work runs in an unstructured task: cancelling the caller does not stop a write that has
    ///   started (a sent request cannot be recalled), it only stops the caller waiting for it.
    /// - Queued: `update`, `deleteItem`, `restoreItem`, `permanentDeleteItem`, `permanentDeleteItems`,
    ///   `setFavorite`, `moveItemToFolder`, `moveItemsToFolder` and `updateAttachments`. Not queued:
    ///   `create` (a new id nothing else can be writing) and the folder and collection methods.
    /// - Not covered: the attachment upload and delete requests run in `AttachmentRepositoryImpl`
    ///   before `updateAttachments` and are outside this queue. One window's edit sheet is modal, so
    ///   they cannot overlap an edit of the same item there.
    private func serialised<T: Sendable>(
        _ ids: [String], _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await serialised(ids, withTrailingTasks: { (try await operation(), [:]) })
    }

    /// The same queue for an operation that hands back background work to keep in it, one task per
    /// item.
    ///
    /// Each trailing task is part of the write to its own item: the tail registered for that item
    /// awaits the operation and then that item's task, so a later write to the item waits for both
    /// and not for the tasks of the other items. The caller resumes with the operation's result as
    /// soon as the operation itself has returned, without waiting for the trailing tasks.
    ///
    /// Why one tail per item and not a second one for the background work: a tail registered after
    /// the operation would replace the first, and the first one's removal check would then pass
    /// over it while the work still runs; a wrapper that returns early must not shorten the queue.
    /// Here each tail stays registered until its trailing task has ended, and is removed then, only
    /// where it is still the registered one (a later write has already queued behind it and
    /// replaced it).
    private func serialised<T: Sendable>(
        _ ids: [String],
        withTrailingTasks operation: @escaping @Sendable () async throws -> (result: T, trailing: [String: Task<Void, Never>])
    ) async throws -> T {
        var seen = Set<String>()
        let ids = ids.filter { seen.insert($0).inserted }
        let previous = ids.compactMap { writeTails[$0] }
        let run = Task<Result<(result: T, trailing: [String: Task<Void, Never>]), Error>, Never> {
            for earlier in previous { await earlier.value }
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        var tails: [String: Task<Void, Never>] = [:]
        for id in ids {
            tails[id] = Task<Void, Never> {
                if case .success(let done) = await run.value, let trailing = done.trailing[id] {
                    await trailing.value
                }
            }
            writeTails[id] = tails[id]
        }
        let outcome = await run.value
        if case .success(let done) = outcome, !done.trailing.isEmpty {
            for (id, tail) in tails {
                Task { [self] in
                    await tail.value
                    releaseTails([id: tail])
                }
            }
            return done.result
        }
        releaseTails(tails)
        return try outcome.get().result
    }

    /// Removes each tail from the id it was registered for, unless a later write replaced it.
    private func releaseTails(_ tails: [String: Task<Void, Never>]) {
        for (id, tail) in tails where writeTails[id] == tail { writeTails[id] = nil }
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
                   l.uris.contains { $0.uri?.localizedCaseInsensitiveContains(query) == true }
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

// MARK: - Bounded concurrency for the bulk refresh

/// Hands out at most `limit` slots at a time, to the oldest waiting request first. The bulk refresh
/// takes one before each fetch, so no more than `limit` fetches are in flight whatever the number of
/// moved items.
private actor FetchSlots {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { free = limit }

    func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            free += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

// MARK: - What a refresh compares

/// Decides whether two server records of one item hold the same item content, from ciphertext and
/// plain members alone: nothing is decrypted, and no key is needed.
///
/// Compared as the JSON each record is sent as (`RawCipher.encode(to:)`), so every member Prizm
/// reads or writes counts, including the unknown keys inside `login`, `fields` and the other
/// rebuilt levels. A record that cannot be encoded is not the same.
nonisolated private enum RecordContent {

    /// Members that change without the item's content changing, or that Prizm's own operations
    /// change: the revision, the trash state, the folder, the favorite flag, the collections, and
    /// the request-only members. A refresh runs after exactly these operations (soft delete,
    /// restore, favorite, move, collection update), so a difference here is expected and says
    /// nothing about another client. Attachments are never encoded, so they are not listed.
    static let ignoredMembers: Set<String> = [
        "revisionDate", "deletedDate", "folderId", "favorite", "collectionIds",
        "encryptedFor", "lastKnownRevisionDate",
    ]

    static func isSame(_ lhs: RawCipher, _ rhs: RawCipher) -> Bool {
        guard let left = members(of: lhs), let right = members(of: rhs) else { return false }
        return left == right
    }

    private static func members(of cipher: RawCipher) -> [String: JSONValue]? {
        guard let data = try? JSONEncoder().encode(cipher),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(var members) = value else { return nil }
        for key in ignoredMembers { members[key] = nil }
        return members
    }
}
