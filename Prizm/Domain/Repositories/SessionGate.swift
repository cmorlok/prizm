import Foundation

// MARK: - SessionGate

/// The one answer to "did a lock or sign-out happen since this flow started?" for every layer
/// (openspec change `lock-state-machine`, design D1).
///
/// - Security goal: after a lock or sign-out, no flow that was running (sign-in, two-factor, unlock,
///   Touch ID, enrollment, token refresh, sync, on-demand decryption) may load keys, install tokens
///   or return decrypted data. Before this type, four counters in three layers were bumped at
///   different moments, and every remaining race lived between two of those moments.
///
/// - Protocol:
///   • A flow calls `begin()` at its FIRST step, synchronously, before any await, and checks
///     `isCurrent(_:)` before each write it guards. A token read right before the write is always
///     current and fences nothing.
///   • Only the initiator of a lock or sign-out calls `end()`, as its first statement. The gate is
///     then closed: `begin()` hands out tokens that are never current, so nothing that starts while
///     the teardown runs can pass a check. The teardown calls `open()` as its last step.
///
/// - `nonisolated`: the module's default isolation is the main actor, but key caches and stores are
///   actors of their own and must check a token in the same turn as their write, without an await.
nonisolated protocol SessionGate: Sendable {
    /// The current epoch's token while the gate is open; a token that is never current while closed.
    func begin() -> FlowToken
    /// Whether `token` belongs to the current epoch and the gate is open.
    func isCurrent(_ token: FlowToken) -> Bool
    /// Closes the gate and makes every token handed out before stale.
    func end()
    /// Opens the gate with a fresh epoch. No-op on an open gate.
    func open()
    /// Whether the gate is open (no lock or sign-out teardown in progress).
    var isOpen: Bool { get }
}

/// A flow's marker of the session epoch it started in; it equals only copies of itself
/// (see `VaultSessionToken`).
// TODO: rename `VaultSessionToken` to `FlowToken` once every caller moved to the gate (task 1.2).
typealias FlowToken = VaultSessionToken
