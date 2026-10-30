import Foundation

/// Configuration for the password/passphrase generator.
/// Persisted to `UserDefaults` as individual keys (UI preference, not vault data).
struct PasswordGeneratorConfig {

    enum Mode: String {
        case password
        case passphrase
    }

    // MARK: - Shared

    var mode: Mode = .password

    // MARK: - Password mode

    var length: Int = 16
    var includeUppercase: Bool = true
    var includeLowercase: Bool = true
    var includeDigits: Bool = true
    /// The special set `!@#$%^&*` (stored under the old key `pwgen.includeSymbols`).
    var includeSymbols: Bool = true
    /// The extended special set `()_+-=[]{}|;':",.<>?/` (fix-password-generator, D2).
    var includeExtendedSymbols: Bool = false
    var avoidAmbiguous: Bool = false
    /// Digits a password contains at least (0–9); 0 behaves like 1 while digits are on.
    var minNumbers: Int = 1
    /// Special characters a password contains at least (0–9); 0 behaves like 1 while special is on.
    var minSpecial: Int = 0

    /// The length a password is generated with: `length`, raised to the sum of the minimums of the
    /// enabled sets when they need more (as the Bitwarden constraints do).
    var effectiveLength: Int {
        var required = 0
        if includeUppercase       { required += 1 }
        if includeLowercase       { required += 1 }
        if includeDigits          { required += max(minNumbers, 1) }
        if includeSymbols         { required += max(minSpecial, 1) }
        if includeExtendedSymbols { required += 1 }
        return max(max(5, min(128, length)), required)
    }

    static let minimumRange = 0...9
    static let wordCountRange = 3...20

    static func clampedWordCount(_ count: Int) -> Int {
        min(max(count, wordCountRange.lowerBound), wordCountRange.upperBound)
    }

    private static func clampedMinimum(_ count: Int) -> Int {
        min(max(count, minimumRange.lowerBound), minimumRange.upperBound)
    }

    // MARK: - Passphrase mode

    var wordCount: Int = 6
    var separator: String = "-"
    var capitalize: Bool = false
    var includeNumber: Bool = false

    // MARK: - UserDefaults persistence

    private enum Key {
        static let mode             = "pwgen.mode"
        static let length           = "pwgen.length"
        static let includeUppercase = "pwgen.includeUppercase"
        static let includeLowercase = "pwgen.includeLowercase"
        static let includeDigits    = "pwgen.includeDigits"
        static let includeSymbols   = "pwgen.includeSymbols"
        static let avoidAmbiguous   = "pwgen.avoidAmbiguous"
        static let includeExtendedSymbols = "pwgen.includeExtendedSymbols"
        static let minNumbers       = "pwgen.minNumbers"
        static let minSpecial       = "pwgen.minSpecial"
        static let wordCount        = "pwgen.wordCount"
        static let separator        = "pwgen.separator"
        static let capitalize       = "pwgen.capitalize"
        static let includeNumber    = "pwgen.includeNumber"
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(length, forKey: Key.length)
        defaults.set(includeUppercase, forKey: Key.includeUppercase)
        defaults.set(includeLowercase, forKey: Key.includeLowercase)
        defaults.set(includeDigits, forKey: Key.includeDigits)
        defaults.set(includeSymbols, forKey: Key.includeSymbols)
        defaults.set(avoidAmbiguous, forKey: Key.avoidAmbiguous)
        defaults.set(includeExtendedSymbols, forKey: Key.includeExtendedSymbols)
        defaults.set(minNumbers, forKey: Key.minNumbers)
        defaults.set(minSpecial, forKey: Key.minSpecial)
        defaults.set(wordCount, forKey: Key.wordCount)
        defaults.set(separator, forKey: Key.separator)
        defaults.set(capitalize, forKey: Key.capitalize)
        defaults.set(includeNumber, forKey: Key.includeNumber)
    }

    static func load(from defaults: UserDefaults = .standard) -> PasswordGeneratorConfig {
        var config = PasswordGeneratorConfig()
        if let raw = defaults.string(forKey: Key.mode), let m = Mode(rawValue: raw) {
            config.mode = m
        }
        if defaults.object(forKey: Key.length) != nil {
            config.length = max(5, min(128, defaults.integer(forKey: Key.length)))
        }
        if defaults.object(forKey: Key.includeUppercase) != nil {
            config.includeUppercase = defaults.bool(forKey: Key.includeUppercase)
        }
        if defaults.object(forKey: Key.includeLowercase) != nil {
            config.includeLowercase = defaults.bool(forKey: Key.includeLowercase)
        }
        if defaults.object(forKey: Key.includeDigits) != nil {
            config.includeDigits = defaults.bool(forKey: Key.includeDigits)
        }
        if defaults.object(forKey: Key.includeSymbols) != nil {
            config.includeSymbols = defaults.bool(forKey: Key.includeSymbols)
        }
        if defaults.object(forKey: Key.avoidAmbiguous) != nil {
            config.avoidAmbiguous = defaults.bool(forKey: Key.avoidAmbiguous)
        }
        if defaults.object(forKey: Key.includeExtendedSymbols) != nil {
            config.includeExtendedSymbols = defaults.bool(forKey: Key.includeExtendedSymbols)
        } else if config.includeSymbols && !config.includeUppercase && !config.includeLowercase
                    && !config.includeDigits {
            // Symbols were the only set before the split into special and extended special: keep
            // the old 29 characters instead of dropping to 8 without notice (design D3).
            config.includeExtendedSymbols = true
        }
        if defaults.object(forKey: Key.minNumbers) != nil {
            config.minNumbers = clampedMinimum(defaults.integer(forKey: Key.minNumbers))
        }
        if defaults.object(forKey: Key.minSpecial) != nil {
            config.minSpecial = clampedMinimum(defaults.integer(forKey: Key.minSpecial))
        }
        if defaults.object(forKey: Key.wordCount) != nil {
            config.wordCount = clampedWordCount(defaults.integer(forKey: Key.wordCount))
        }
        if let sep = defaults.string(forKey: Key.separator) {
            config.separator = sep
        }
        if defaults.object(forKey: Key.capitalize) != nil {
            config.capitalize = defaults.bool(forKey: Key.capitalize)
        }
        if defaults.object(forKey: Key.includeNumber) != nil {
            config.includeNumber = defaults.bool(forKey: Key.includeNumber)
        }
        return config
    }
}
