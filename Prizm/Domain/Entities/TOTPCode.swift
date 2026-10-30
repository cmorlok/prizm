import Foundation

/// A one-time code ready to display: the digits, the validity period it came from, and how long
/// is left. Never persisted; it is shown, copied, and discarded (see data-model.md).
nonisolated struct TOTPCode: Equatable {
    /// Exactly `configuration.digits` characters: zero-padded digits (RFC 4226 §5.3 keeps leading
    /// zeros), or Steam Guard letters and digits.
    let digits: String
    /// Validity period in seconds, copied from the configuration.
    let period: Int
    /// 1 to `period`. Equals `period` exactly at a period boundary.
    let secondsRemaining: Int

    /// The code split in the middle for readability ("123 456"), with the smaller half first, as
    /// the official apps do; codes of up to four characters stay whole (totp-parity, design D4a).
    var grouped: String {
        guard digits.count > 4 else { return digits }
        let split = digits.count / 2
        let head = digits.prefix(split)
        let tail = digits.dropFirst(split)
        return "\(head) \(tail)"
    }

    /// The value to put on the clipboard: digits only, so it pastes into any code field.
    var copyValue: String { digits }

    /// True during the last seconds of validity, when the UI should warn the user (FR-001a).
    var isExpiringSoon: Bool { secondsRemaining <= Self.warningSeconds }

    static let warningSeconds = 5
}
