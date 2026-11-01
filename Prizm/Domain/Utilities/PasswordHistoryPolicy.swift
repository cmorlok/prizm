import Foundation

/// Which values a save adds to an item's password history, as the official Bitwarden clients
/// decide it (sdk-internal `c1c9b9a5`: `cipher.rs:1009-1027` `update_password_history`,
/// `login.rs:387-413` `detect_password_change`, `field.rs:126-158` `detect_hidden_field_changes`).
///
/// Works on bytes, not `String`: the caller decrypts the stored values into `Data` it can zero
/// after encrypting the entries (Constitution §III), and zeroes the returned entries too. Best
/// effort: the dictionary and set used to match names hold their own copies, and Foundation keeps
/// short `Data` values (14 bytes or less) inline, so those copies are freed without zeroing.
nonisolated enum PasswordHistoryPolicy {

    /// `MAX_PASSWORD_HISTORY_ENTRIES` in `password_history.rs:13`.
    static let maxEntries = 5

    /// A custom field of type hidden, name and value as UTF-8.
    struct HiddenField {
        var name: Data
        var value: Data

        /// Zeroes both buffers, for the caller's cleanup.
        mutating func wipe() {
            name.resetBytes(in: name.indices)
            value.resetBytes(in: value.indices)
        }
    }

    /// The plaintext entries to put in front of the stored history, newest first.
    ///
    /// - Password: an empty old password adds nothing (a first password only sets the revision
    ///   date), an unchanged one adds nothing, a changed or cleared one adds the old password.
    ///   `oldPassword` is nil when the stored item has no login section (nothing is compared).
    /// - Hidden fields: each stored hidden field with a non-empty name and value whose name the
    ///   draft no longer has, or whose value there differs, adds `"<name>: <old value>"`. Fields are
    ///   matched by name, so a rename counts as a removal. For a name given twice the last field
    ///   wins on both sides, as the SDK's `HashMap`. Fields with an empty name or value are ignored.
    /// - Order: the SDK lists the password first, then the fields, and reverses that list before
    ///   prepending it. Its field order comes from a `HashMap` and is unspecified; here it is the
    ///   stored order of first appearance.
    static func newEntries(oldPassword: Data?, newPassword: Data,
                           oldHidden: [HiddenField], newHidden: [HiddenField]) -> [Data] {
        var entries: [Data] = []
        if let oldPassword, !oldPassword.isEmpty, oldPassword != newPassword {
            entries.append(oldPassword)
        }
        let current = lastValueByName(newHidden)
        for (name, value) in orderedLastValueByName(oldHidden) where current[name] != value {
            entries.append(name + Data(": ".utf8) + value)
        }
        return entries.reversed()
    }

    private static func usable(_ fields: [HiddenField]) -> [HiddenField] {
        fields.filter { !$0.name.isEmpty && !$0.value.isEmpty }
    }

    private static func lastValueByName(_ fields: [HiddenField]) -> [Data: Data] {
        var map: [Data: Data] = [:]
        for field in usable(fields) { map[field.name] = field.value }
        return map
    }

    private static func orderedLastValueByName(_ fields: [HiddenField]) -> [(Data, Data)] {
        let map = lastValueByName(fields)
        var seen = Set<Data>()
        return usable(fields).compactMap { field in
            guard seen.insert(field.name).inserted, let value = map[field.name] else { return nil }
            return (field.name, value)
        }
    }
}
