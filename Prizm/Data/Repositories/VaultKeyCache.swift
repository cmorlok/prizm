import Foundation
import os.log

// MARK: - CipherKeySource

/// Where an item's effective key comes from (fix-org-attachment-key, D1).
///
/// Official rule (SDK `bitwarden-vault/src/cipher/cipher.rs`, `decrypt_cipher_key` and
/// `key_identifier`): an item with its own key uses that key, unwrapped with the owning key; an
/// item without one uses the owning key itself, which is the organization key for an organization
/// item and the user's vault key otherwise.
///
/// Only an item's own key is stored as bytes. Organization and vault keys stay in `OrgKeyCache`
/// and the crypto service, so an org key replaced by the next sync is never read from a stale copy.
nonisolated enum CipherKeySource: Equatable, Sendable {
    /// The item's own 64-byte key (encryptionKey ‖ macKey), already unwrapped.
    case itemKey(Data)
    /// An organization item without its own key: the organization's key.
    case organization(orgId: String)
    /// A personal item without its own key: the user's vault key.
    case personal

    /// The source of `raw`, given the effective key `CipherMapper` resolved for it.
    static func of(_ raw: RawCipher, effectiveKey: Data) -> CipherKeySource {
        if raw.key != nil { return .itemKey(effectiveKey) }
        if let orgId = raw.organizationId { return .organization(orgId: orgId) }
        return .personal
    }
}

// MARK: - VaultKeyCache

/// In-memory cache mapping cipher IDs to the source of their effective key.
///
/// - Security goal: keeps per-cipher key material close to where it is used
///   (attachment operations) without storing it on `VaultItem` domain entities,
///   which would expose key material to the Presentation layer.
///
/// - Populated at sync time by `SyncRepositoryImpl` via `populate(sources:)` with an entry for
///   every item, and by `VaultRepositoryImpl.create` via `record(_:for:)` for a new item, so no
///   item has to fall back to a guessed key (fix-org-attachment-key, D2). Cleared alongside the
///   vault store on lock/sign-out.
///
/// - Thread safety: declared as `actor` because it is written from the sync path
///   (background `actor SyncRepositoryImpl`) and read from attachment operation paths
///   (`VaultKeyServiceImpl`). An `actor` prevents data races under Swift 6 strict
///   concurrency checking (Constitution §II — "actor for shared mutable state in
///   Data layer").
actor VaultKeyCache {

    private let logger = Logger(subsystem: "com.prizm", category: "VaultKeyCache")

    /// Maps cipher ID → key source.
    private var cache: [String: CipherKeySource] = [:]

    // MARK: - Public API

    #if DEBUG
    /// Test seam: each per-item key right after zeroing, and whether it was zeroed in place.
    private var zeroedObserver: (@Sendable (Data, Bool) -> Void)?
    func setZeroedObserver(_ observer: (@Sendable (Data, Bool) -> Void)?) {
        zeroedObserver = observer
    }
    #endif

    /// Replaces the entire cache with the provided mapping, if the sync's session is still current.
    ///
    /// Called by `SyncRepositoryImpl` after sync completes. This is a wholesale
    /// replace (not a merge) so stale entries from a previous sync are evicted.
    ///
    /// - Security goal: a lock between the sync's last lock check and this write must not leave the
    ///   new sources, item keys included, in the cache the lock just cleared (openspec change
    ///   `lock-state-machine`, gap 6). `isStillCurrent` is evaluated here, inside the actor and in
    ///   the same turn as the write, so no lock can land between check and write.
    /// - A refused write zeroes the item keys it was given (best effort: a buffer shared with the
    ///   caller is copied on write and only the copy is zeroed; see SECURITY.md).
    /// - Intentionally NOT done: zeroing the replaced keys. The sync passes overlapping maps (the
    ///   personal pass, then the org pass with the same buffers), so zeroing here could wipe keys
    ///   still in use; they are dropped and stay until the memory is reused (SECURITY.md).
    /// - Returns: false when the session ended; the cache is unchanged then.
    @discardableResult
    func populate(sources: [String: CipherKeySource], ifStillCurrent isStillCurrent: @Sendable () -> Bool) -> Bool {
        guard isStillCurrent() else {
            var refused = sources
            zeroItemKeys(in: &refused)
            logger.info("VaultKeyCache: \(sources.count, privacy: .public) source(s) not written: the session ended")
            return false
        }
        cache = sources
        logger.info("VaultKeyCache populated: \(sources.count, privacy: .public) entry/entries")
        return true
    }

    #if DEBUG
    /// Test seam: replaces the cache without a session check, for tests that set up a cache.
    func populate(sources: [String: CipherKeySource]) {
        populate(sources: sources, ifStillCurrent: { true })
    }
    #endif

    /// Adds or replaces the entry of one item, keeping the others (a new item after a create).
    ///
    /// - Security goal: a create that a lock overtook must not leave its key source (and item key)
    ///   in the next session. `isStillCurrent` is the session gate's check of the create's token,
    ///   evaluated inside the actor in the write's turn (lock-state-machine, task 1.2); a refused
    ///   item key is zeroed.
    func record(_ source: CipherKeySource, for cipherId: String, ifStillCurrent isStillCurrent: @Sendable () -> Bool) {
        guard isStillCurrent() else {
            var refused = [cipherId: source]
            zeroItemKeys(in: &refused)
            logger.info("Key source of \(cipherId, privacy: .public) not recorded: the session ended since the request began")
            return
        }
        cache[cipherId] = source
    }

    /// The key source of the given cipher ID, or `nil` if neither the last sync nor a create
    /// since recorded it.
    func source(for cipherId: String) -> CipherKeySource? {
        cache[cipherId]
    }

    /// The item's own key, or `nil` when it has none (or is unknown).
    func key(for cipherId: String) -> Data? {
        if case .itemKey(let key)? = cache[cipherId] { return key }
        return nil
    }

    /// Zeros all key material and clears the cache.
    ///
    /// Called on vault lock and sign-out — mirrors the lifecycle of `VaultRepositoryImpl`.
    /// Zeroing before clearing reduces the window during which key bytes remain on the
    /// heap after the cache is discarded (Constitution §III).
    func clear() {
        zeroItemKeys(in: &cache)
        cache.removeAll()
        logger.info("VaultKeyCache cleared — key material zeroed")
    }

    /// Zeroes every item key in `map` and replaces it with `.personal`.
    private func zeroItemKeys(in map: inout [String: CipherKeySource]) {
        // Iterate over a copy of the ids: a live `map.keys` view holds the dictionary's storage,
        // so the first write would copy the dictionary and its key buffers and zero only the copy.
        for id in Array(map.keys) {
            guard case .itemKey(var key)? = map[id] else { continue }
            // Take the buffer out of the dictionary first, so it has one owner and is zeroed in
            // place, not in a copy made by copy-on-write. Slices need their actual indices.
            map[id] = .personal
            #if DEBUG
            let before = key.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
            #endif
            key.resetBytes(in: key.indices)
            #if DEBUG
            let after = key.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
            zeroedObserver?(key, before == after)
            #endif
        }
    }
}
