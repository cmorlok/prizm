import Foundation
import os.log
import Synchronization

// MARK: - RawCipherStore

/// Holds the last server-confirmed `RawCipher` of every item, as received: ciphertext and plain
/// metadata, in memory only.
///
/// - Security goal: keep the server's own record so that a later edit can send back what Prizm does
///   not model (passkeys, password history, other clients' fields; OpenSpec change
///   `fix-cipher-edit-data-loss`, design D1). It never holds keys or decrypted values, and it is
///   never written to disk, UserDefaults or the Keychain. A record from one session must not
///   survive into the locked state or into the next account, so `clear()` runs first in
///   `VaultRepositoryImpl.clearVault()`, which lock and sign-out both reach.
///
/// - Filled by: sync (every cipher of the response, including ones that fail to decrypt), create
///   and update (the server's answer). Emptied by: permanent delete (per id) and `clear()`.
///
/// - The fence: `clear()` and `invalidate()` replace the current `Generation` token with a new one.
///   Every write takes the token an operation read when it STARTED and is refused when it is stale.
///   The token must be read at the start of a sync or save, before its first network await: a token
///   read right before the write is always current and fences nothing. A write that is refused
///   changes nothing. This closes two races that a lock check cannot: a sync or save that finishes
///   after the lock cleared the vault, and a lock followed by an unlock, which makes `isUnlocked`
///   true again for the old operation.
///
/// - The generation is read, compared and replaced synchronously (`currentGeneration()`,
///   `isCurrent(_:)` and `invalidate()` are `nonisolated` over a lock-protected token). That lets
///   `VaultRepositoryImpl` check a token and write its own item cache in ONE actor turn, with no
///   suspension point in between: an `await` between the check and the write would let a lock land
///   after the check, and the plaintext item would be cached anyway. Tokens for the repository's
///   item cache and for `populate` come from here too, so this stays the one lock fence of the Data
///   layer.
///
/// - Intentionally NOT done:
///   • No zeroing on `clear()`: the store holds ciphertext and metadata the server already has,
///     never keys or plaintext, unlike the key caches.
///   • The store fences its own writes. The repository's item cache is fenced by the repository,
///     which checks `isCurrent(_:)` itself right before the write; `populate` is fenced the same
///     way with the token its sync read at the start. The per-item write queue and the refresh
///     after Prizm's own operations are later stale-write protection work (OpenSpec tasks 4.5 and
///     4.4).
///   • Restore, soft delete, attachment and collection changes do not refresh the record; that
///     belongs to stale-write protection (OpenSpec task 4.4). The record can therefore be older
///     than the server's until the next sync.
///   • No fallback for a missing record: `VaultRepositoryImpl.update` reads the store and refuses a
///     full save without a record (`itemRecordUnavailable`), so the store is not optional.
///
/// - Only a token handed out here can be current (a `VaultSessionToken` equals only copies of
///   itself). Tokens are independent of `AuthRepositoryImpl.lockEpoch` and of the view model's lock
///   generation, so the open `lock-state-machine` change can derive them from its session token
///   later without changing any caller.
///
/// - Logging: counts only. Neither the records nor their ids are logged here, and the type prints
///   as "RawCipherStore(redacted)".
actor RawCipherStore {

    /// The token type is shared with Domain (`VaultRepository.populate` carries it). A token built
    /// anywhere else is never current, and none survives a `clear()`.
    typealias Generation = VaultSessionToken

    private let logger = Logger(subsystem: "com.prizm", category: "RawCipherStore")

    /// The current token behind the fence. A `Mutex` and not an actor-isolated `var`, so that the
    /// check in `isCurrent(_:)` needs no suspension (see the type comment).
    private let generation = Mutex<Generation>(Generation())
    private var records: [String: RawCipher] = [:]

    // MARK: - Fence

    /// The current generation. Read it at the start of the operation whose writes it guards.
    nonisolated func currentGeneration() -> Generation {
        generation.withLock { $0 }
    }

    /// Whether `token` is still the current generation, i.e. nothing cleared the vault since.
    nonisolated func isCurrent(_ token: Generation) -> Bool {
        generation.withLock { $0 } == token
    }

    /// Makes every token handed out before stale, without touching the records. `clear()` calls it;
    /// `VaultRepositoryImpl.clearVault()` calls it first, before any suspension, so that a save on
    /// the repository's own actor sees the lock at its next check. Idempotent in effect.
    nonisolated func invalidate() {
        generation.withLock { $0 = Generation() }
    }

    // MARK: - Writes

    /// Replaces every record with `ciphers` (a sync). A repeated id keeps its last entry.
    /// - Returns: false and changes nothing when `token` is stale.
    @discardableResult
    func replaceAll(_ ciphers: [RawCipher], ifCurrent token: Generation) -> Bool {
        guard isCurrent(token) else { return false }
        records = Dictionary(ciphers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        logger.info("RawCipherStore: replaced with \(ciphers.count, privacy: .public) record(s)")
        return true
    }

    /// Stores or replaces the record of one item (a create or an update).
    /// - Returns: false and changes nothing when `token` is stale.
    @discardableResult
    func upsert(_ cipher: RawCipher, ifCurrent token: Generation) -> Bool {
        guard isCurrent(token) else { return false }
        records[cipher.id] = cipher
        return true
    }

    /// Removes the records of `ids` (a permanent delete); an unknown id is ignored.
    /// - Returns: false and changes nothing when `token` is stale.
    @discardableResult
    func remove(ids: [String], ifCurrent token: Generation) -> Bool {
        guard isCurrent(token) else { return false }
        for id in ids { records[id] = nil }
        return true
    }

    /// Drops every record and invalidates every token handed out before. Idempotent.
    func clear() {
        records = [:]
        invalidate()
        logger.info("RawCipherStore: cleared")
    }

    // MARK: - Reads

    func record(for id: String) -> RawCipher? {
        records[id]
    }

    var count: Int {
        records.count
    }
}

// `nonisolated`: without it the conformances of an actor are main-actor isolated under the module's
// default isolation and do not compile. `CustomReflectable` keeps `dump` from listing the records.
nonisolated extension RawCipherStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "RawCipherStore(redacted)" }
    nonisolated var debugDescription: String { "RawCipherStore(redacted)" }
    nonisolated var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}
