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
///   and update (the server's answer), and every other own operation of the repository: soft delete,
///   restore, attachment changes, favorite and moves, and the collection update of an organization
///   item (the restore or collections answer, or a fetch of the item:
///   `VaultRepositoryImpl.refreshRecord`). Emptied by: permanent delete (per id) and `clear()`.
///
/// - The fence: the `Generation` token is the session gate's (lock-state-machine, design D1). The
///   lock or sign-out ends the gate as its first step, before `clearVault()`; the store itself never
///   ends or opens it, so no caller of `clear()` can leave the gate closed.
///   Every write takes the token an operation read when it STARTED and is refused when it is stale.
///   The token must be read at the start of a sync or save, before its first network await: a token
///   read right before the write is always current and fences nothing. A write that is refused
///   changes nothing. This closes two races that a lock check cannot: a sync or save that finishes
///   after the lock cleared the vault, and a lock followed by an unlock, which makes `isUnlocked`
///   true again for the old operation.
///
/// - The generation is read, compared and replaced synchronously (`currentGeneration()`,
///   `isCurrent(_:)` are `nonisolated` over the gate's lock-protected token). That lets
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
///     way with the token its sync read at the start.
///   • A refresh that cannot reach the server leaves the record as it was, so the record can be older
///     than the server's until the next sync; the cost is one conflict on a later edit, and a reload
///     resolves it.
///   • No fallback for a missing record: `VaultRepositoryImpl.update` reads the store and refuses a
///     full save without a record (`itemRecordUnavailable`), so the store is not optional.
///
/// - Only a token handed out by the session gate can be current (a `FlowToken` equals only copies
///   of itself). The store's generation is the gate's token, so a sign-in or unlock passes its own
///   flow token to the sync that ends it (lock-state-machine, design D1, D8).
///
/// - Logging: counts only. Neither the records nor their ids are logged here, and the type prints
///   as "RawCipherStore(redacted)".
actor RawCipherStore {

    /// The token type is shared with Domain (`VaultRepository.populate` carries it). A token built
    /// anywhere else is never current, and none survives a `clear()`.
    typealias Generation = FlowToken

    private let logger = Logger(subsystem: "com.prizm", category: "RawCipherStore")

    /// The lock fence. Its token is the store's generation (openspec change `lock-state-machine`,
    /// design D1): one gate for every layer, so a lock seen by the view model is seen here too.
    /// `AppContainer` passes the app's gate; a store built without one has a private gate.
    private let gate: any SessionGate
    private var records: [String: RawCipher] = [:]

    init(gate: any SessionGate = SessionGateImpl()) {
        self.gate = gate
    }

    // MARK: - Fence

    /// The current generation. Read it at the start of the operation whose writes it guards.
    nonisolated func currentGeneration() -> Generation {
        gate.begin()
    }

    /// Whether `token` is still the current generation, i.e. nothing cleared the vault since.
    nonisolated func isCurrent(_ token: Generation) -> Bool {
        gate.isCurrent(token)
    }

    #if DEBUG
    /// Test seam: the lock's first step, as `RootViewModel` takes it (`gate.end()`), for Data tests
    /// without a root. Every token handed out before is stale; the records stay.
    nonisolated func invalidate() {
        gate.end()
    }

    /// Test seam: opens the gate as `RootViewModel`'s teardown does at its end, for Data tests that
    /// model "lock, then unlock" with `clearVault()` alone.
    nonisolated func openAfterTeardown() {
        gate.open()
    }
    #endif

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
        logger.info("RawCipherStore: cleared")
    }

    // MARK: - Reads

    func record(for id: String) -> RawCipher? {
        records[id]
    }

    var count: Int {
        records.count
    }

    /// Whether the server keeps archive state, judged from the stored records
    /// (`LegacyArchiveSupport.isSupported(records:)`, archived-items D5).
    var keepsArchiveState: Bool {
        LegacyArchiveSupport.isSupported(records: Array(records.values))
    }
}

// `nonisolated`: without it the conformances of an actor are main-actor isolated under the module's
// default isolation and do not compile. `CustomReflectable` keeps `dump` from listing the records.
nonisolated extension RawCipherStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "RawCipherStore(redacted)" }
    nonisolated var debugDescription: String { "RawCipherStore(redacted)" }
    nonisolated var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}
