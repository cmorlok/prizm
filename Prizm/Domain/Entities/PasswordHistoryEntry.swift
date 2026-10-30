import Foundation

/// One entry of an item's password history, decrypted only while the history sheet shows it
/// (openspec change `password-history`, design D1). The value is the old password, or
/// `"<name>: <value>"` for a hidden custom field, as the Bitwarden SDK records it.
nonisolated struct PasswordHistoryEntry: Equatable, Sendable {
    /// Nil when the stored entry could not be read: not an object, no `password`, or it does not
    /// decrypt under the item's key. Shown as "Entry could not be read", without reveal or copy.
    let value: String?
    /// Nil when the stored date is missing or not a date ("Unknown date").
    let lastUsedDate: Date?
}
