import Foundation
import os.log

// MARK: - OrgKeyCache

/// In-memory cache mapping organization IDs to their unwrapped symmetric keys.
///
/// - Security goal: keeps org key material in the Data layer behind a protocol boundary,
///   preventing exposure to the Presentation layer. Org keys are zeroed before removal
///   (Constitution §III) to reduce the heap-residency window after lock.
///
/// - Populated at sync time by `SyncRepositoryImpl` after unwrapping each org's RSA-encrypted
///   symmetric key, and replaced in one step on every sync (`replaceAll`). Zeroed and cleared
///   by `AuthRepositoryImpl.lockVault()`, the teardown for lock and sign-out.
///   Reference: Bitwarden Security Whitepaper §4 — "Organization Key Wrapping".
///
/// - Thread safety: declared as `actor` because it is written from the sync path
///   (background `actor SyncRepositoryImpl`) and read from `CipherMapper` via a
///   synchronous snapshot. An `actor` prevents data races under Swift 6 strict
///   concurrency checking (Constitution §II — "actor for shared mutable state in
///   Data layer").
actor OrgKeyCache {

    private let logger = Logger(subsystem: "com.prizm", category: "OrgKeyCache")

    /// Maps organization ID → unwrapped 64-byte symmetric key (encKey ‖ macKey).
    private var cache: [String: CryptoKeys] = [:]

    // MARK: - Public API

    /// Stores the org's symmetric key in the cache.
    ///
    /// - Parameters:
    ///   - key:   The unwrapped 64-byte `CryptoKeys` for the organization.
    ///   - orgId: The organization's ID string.
    func store(key: CryptoKeys, for orgId: String) {
        cache[orgId] = key
        logger.info("OrgKeyCache: stored key for org \(orgId.prefix(8), privacy: .public)…")
    }

    /// Returns a value-type snapshot of the cache for synchronous use in `CipherMapper`.
    ///
    /// Why a snapshot instead of passing the actor reference: `CipherMapper.map()` is
    /// synchronous. Passing a `[String: CryptoKeys]` value copy avoids actor-isolation
    /// crossings inside the tight per-cipher decryption loop, keeping it synchronous and
    /// non-throwing from an async perspective.
    func snapshot() -> [String: CryptoKeys] {
        cache
    }

    /// Zeros all org key material and clears the cache.
    ///
    /// Called by `AuthRepositoryImpl.lockVault()` (lock and sign-out) alongside `VaultKeyCache.clear()`.
    /// Zeroing before clearing reduces the window during which key bytes remain on the
    /// heap after the cache is discarded (Constitution §III).
    func clear() {
        zero(&cache)
        cache.removeAll()
        logger.info("OrgKeyCache cleared — key material zeroed")
    }

    /// Replaces all org keys in one step and zeroes the replaced ones.
    ///
    /// Security goal: a save that runs during a sync sees either the previous keys or the new ones,
    /// never an empty map, so it can never take a path without the org key
    /// (fix-org-key-required-on-write, D2). Called once per sync after every org key is unwrapped;
    /// orgs that are not in `newKeys` have no key afterwards.
    func replaceAll(with newKeys: [String: CryptoKeys]) {
        var replaced = cache
        cache = newKeys
        zero(&replaced)
        logger.info("OrgKeyCache replaced: \(newKeys.count, privacy: .public) org key(s)")
    }

    #if DEBUG
    /// A key as it was right after zeroing, and whether both halves were zeroed in place.
    struct ZeroedOrgKey: Sendable {
        let encryptionKey: Data
        let macKey: Data
        let inPlace: Bool
    }
    /// Test seam: called for each org key after it is zeroed.
    private var zeroedObserver: (@Sendable (ZeroedOrgKey) -> Void)?
    func setZeroedObserver(_ observer: (@Sendable (ZeroedOrgKey) -> Void)?) {
        zeroedObserver = observer
    }
    #endif

    /// Zeroes the key bytes in `keys` in place.
    private func zero(_ keys: inout [String: CryptoKeys]) {
        // Data slices retain their original indices (the RSA-unwrapped MAC key
        // starts at 32). A zero-based range can overwrite memory outside the slice.
        // Capture ranges before mutation to avoid overlapping dictionary accesses.
        // CoW means outstanding snapshots retain their own buffers (see SECURITY.md).
        // Iterate over a copy of the ids: a live `keys.keys` view holds the dictionary's storage,
        // so the first write would copy the dictionary and its key buffers and zero only the copy.
        for key in Array(keys.keys) {
            if let encRange = keys[key]?.encryptionKey.indices,
               let macRange = keys[key]?.macKey.indices {
                #if DEBUG
                let before = keys[key].map(Self.addresses)
                #endif
                keys[key]?.encryptionKey.resetBytes(in: encRange)
                keys[key]?.macKey.resetBytes(in: macRange)
                #if DEBUG
                if let zeroed = keys[key] {
                    zeroedObserver?(ZeroedOrgKey(encryptionKey: zeroed.encryptionKey, macKey: zeroed.macKey,
                                                 inPlace: before.map { $0 == Self.addresses(zeroed) } ?? false))
                }
                #endif
            }
        }
    }

    #if DEBUG
    private static func addresses(_ keys: CryptoKeys) -> [UInt] {
        [keys.encryptionKey, keys.macKey].map { data in data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) } }
    }
    #endif
}
