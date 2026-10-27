import Foundation
import os.log

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
/// - The fence: `clear()` bumps an opaque `Generation`. Every write takes the token an operation
///   read when it STARTED and is refused when it is stale. The token must be read at the start of a
///   sync or save, before its first network await: a token read right before the write is always
///   current and fences nothing. A write that is refused changes nothing. This closes two races
///   that a lock check cannot: a sync or save that finishes after the lock cleared the vault, and a
///   lock followed by an unlock, which makes `isUnlocked` true again for the old operation.
///
/// - Intentionally NOT done:
///   • No zeroing on `clear()`: the store holds ciphertext and metadata the server already has,
///     never keys or plaintext, unlike the key caches.
///   • The fence covers store writes only. `VaultRepositoryImpl.populate` and a save's own item
///     cache update after a lock are fenced by stale-write protection (OpenSpec task 4.5).
///   • Restore, soft delete, attachment and collection changes do not refresh the record; that
///     belongs to stale-write protection (OpenSpec task 4.4). The record can therefore be older
///     than the server's until the next sync.
///   • No fallback for a missing record: `VaultRepositoryImpl.update` reads the store and refuses a
///     full save without a record (`itemRecordUnavailable`), so the store is not optional.
///
/// - The token is private to this type and independent of `AuthRepositoryImpl.lockEpoch` and of
///   the view model's lock generation, so the open `lock-state-machine` change can derive it from
///   its session token later without changing any caller.
///
/// - Logging: counts only. Neither the records nor their ids are logged here, and the type prints
///   as "RawCipherStore(redacted)".
actor RawCipherStore {

    /// Opaque: callers can only get one from `currentGeneration()`, so they cannot forge a current
    /// token or keep one across a `clear()`.
    nonisolated struct Generation: Equatable, Sendable {
        fileprivate let value: Int
    }

    private let logger = Logger(subsystem: "com.prizm", category: "RawCipherStore")

    private var generation = Generation(value: 0)
    private var records: [String: RawCipher] = [:]

    // MARK: - Fence

    /// The current generation. Read it at the start of the operation whose writes it guards.
    func currentGeneration() -> Generation {
        generation
    }

    // MARK: - Writes

    /// Replaces every record with `ciphers` (a sync). A repeated id keeps its last entry.
    /// - Returns: false and changes nothing when `token` is stale.
    @discardableResult
    func replaceAll(_ ciphers: [RawCipher], ifCurrent token: Generation) -> Bool {
        guard token == generation else { return false }
        records = Dictionary(ciphers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        logger.info("RawCipherStore: replaced with \(ciphers.count, privacy: .public) record(s)")
        return true
    }

    /// Stores or replaces the record of one item (a create or an update).
    /// - Returns: false and changes nothing when `token` is stale.
    @discardableResult
    func upsert(_ cipher: RawCipher, ifCurrent token: Generation) -> Bool {
        guard token == generation else { return false }
        records[cipher.id] = cipher
        return true
    }

    /// Removes the records of `ids` (a permanent delete); an unknown id is ignored.
    /// - Returns: false and changes nothing when `token` is stale.
    @discardableResult
    func remove(ids: [String], ifCurrent token: Generation) -> Bool {
        guard token == generation else { return false }
        for id in ids { records[id] = nil }
        return true
    }

    /// Drops every record and invalidates every token handed out before. Idempotent.
    func clear() {
        records = [:]
        // Wrapping add: the value only has to differ from the tokens in flight, and a trap here
        // would turn a lock into a crash.
        generation = Generation(value: generation.value &+ 1)
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
