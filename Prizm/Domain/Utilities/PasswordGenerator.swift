import Foundation

/// Why the generator produced nothing. Shown in the generator popover, so each case has a text.
enum PasswordGeneratorError: LocalizedError, Equatable {
    /// The bundled word list is missing, unreadable or not the 7,776-word EFF list.
    case wordListUnavailable
    /// The random source returned 64 rejected values in a row (design D1): treated as broken.
    case randomSourceFailed

    var errorDescription: String? {
        switch self {
        case .wordListUnavailable: return "The word list for passphrases couldn't be loaded."
        case .randomSourceFailed:  return "The system's random source failed. Nothing was generated."
        }
    }
}

/// Where passphrase words come from. Injected so a missing list can be tested.
protocol WordListSource {
    func words() throws -> [String]
}

/// The EFF Large Wordlist bundled with the app (`eff-large-wordlist.txt`), read once and cached.
struct BundleWordListSource: WordListSource {

    private static let cached: [String]? = {
        guard let url = Bundle.main.url(forResource: "eff-large-wordlist", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }()

    func words() throws -> [String] {
        guard let words = Self.cached else { throw PasswordGeneratorError.wordListUnavailable }
        return words
    }
}

/// Pure-Swift password and passphrase generator.
/// Receives randomness via `RandomnessProvider` injection — no Security.framework dependency.
struct PasswordGenerator {

    // MARK: - Character sets

    private static let uppercaseChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let lowercaseChars = Array("abcdefghijklmnopqrstuvwxyz")
    private static let digitChars     = Array("0123456789")
    /// Bitwarden's special characters, the set sites accept most widely.
    static let specialChars           = Array("!@#$%^&*")
    /// The rest of Prizm's earlier symbol set; its own option because sites and shells reject
    /// these most often (quotes, `<>`, `|`, `;`). Disjoint from `specialChars`.
    static let extendedSpecialChars   = Array("()_+-=[]{}|;':\",.<>?/")
    private static let ambiguousChars: Set<Character> = ["0", "O", "I", "l", "1", "|"]

    /// Size of the EFF Large Wordlist before the hyphenated words are removed.
    private static let effWordCount = 7_776
    private static let effUsableWordCount = 7_772

    private let wordListSource: any WordListSource

    init(wordListSource: any WordListSource = BundleWordListSource()) {
        self.wordListSource = wordListSource
    }

    // MARK: - Uniform choice

    /// A uniformly distributed index in `0..<n`.
    ///
    /// - Security goal: every character, position and word of a generated secret is equally
    ///   likely, so its strength is exactly what its length and set sizes promise.
    /// - Algorithm: rejection sampling, the same property as `random_range` in the Bitwarden SDK
    ///   (`bitwarden-generators`, `password.rs:174-178`). A 32-bit draw at or above the largest multiple of
    ///   `n` below 2^32 is rejected; the rest are reduced modulo `n`. The limit is computed in
    ///   `UInt64` because 2^32 does not fit in a `UInt32`.
    /// - Not done: a non-throwing `RandomNumberGenerator` wrapper, which would have to crash or
    ///   swallow a provider failure (§V).
    /// - Throws: the provider's error, or `randomSourceFailed` after 64 rejections in a row, so a
    ///   broken source cannot freeze the popover; a working one gets there with probability below
    ///   (7776 / 2^32)^64.
    static func uniformIndex(below n: Int, using provider: RandomnessProvider) throws -> Int {
        precondition(n > 0 && UInt64(n) <= UInt64(UInt32.max), "uniformIndex: n out of range")
        let limit = (UInt64(1) << 32) / UInt64(n) * UInt64(n)
        for _ in 0..<64 {
            let bytes = try provider.randomBytes(count: 4)
            let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if value < limit { return Int(value % UInt64(n)) }
        }
        throw PasswordGeneratorError.randomSourceFailed
    }

    // MARK: - Password generation

    /// Generates a random character-based password.
    ///
    /// Each enabled set contributes its minimum (at least 1), the rest comes from the union of the
    /// enabled sets, then a Fisher–Yates shuffle; the same order as the Bitwarden SDK.
    /// - Throws: `PasswordGeneratorError` or the provider's error.
    func generatePassword(config: PasswordGeneratorConfig, provider: RandomnessProvider) throws -> String {
        var sets: [(chars: [Character], minimum: Int)] = []
        if config.includeUppercase       { sets.append((Self.uppercaseChars, 1)) }
        if config.includeLowercase       { sets.append((Self.lowercaseChars, 1)) }
        if config.includeDigits          { sets.append((Self.digitChars, max(config.minNumbers, 1))) }
        if config.includeSymbols         { sets.append((Self.specialChars, max(config.minSpecial, 1))) }
        if config.includeExtendedSymbols { sets.append((Self.extendedSpecialChars, 1)) }
        // The view never lets the last set be switched off; a config built elsewhere falls back
        // to lowercase rather than producing nothing.
        if sets.isEmpty { sets.append((Self.lowercaseChars, 1)) }
        if config.avoidAmbiguous {
            sets = sets.map { ($0.chars.filter { !Self.ambiguousChars.contains($0) }, $0.minimum) }
        }

        let pool = sets.flatMap(\.chars)
        var result: [Character] = []
        for set in sets {
            for _ in 0..<set.minimum {
                result.append(set.chars[try Self.uniformIndex(below: set.chars.count, using: provider)])
            }
        }
        while result.count < config.effectiveLength {
            result.append(pool[try Self.uniformIndex(below: pool.count, using: provider)])
        }
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            result.swapAt(i, try Self.uniformIndex(below: i + 1, using: provider))
        }
        return String(result)
    }

    // MARK: - Passphrase generation

    /// The EFF Large Wordlist without its four hyphenated words (`drop-down`, `felt-tip`,
    /// `t-shirt`, `yo-yo`), which make "-"-separated passphrases ambiguous.
    /// - Throws: `wordListUnavailable` when the source fails or does not hold exactly 7,776 words,
    ///   so a truncated resource cannot pass.
    func wordList() throws -> [String] {
        let words = try wordListSource.words()
        guard words.count == Self.effWordCount else { throw PasswordGeneratorError.wordListUnavailable }
        let usable = words.filter { !$0.contains("-") }
        // The EFF list has 4 hyphenated words; any other count means a wrong resource.
        guard usable.count == Self.effUsableWordCount else { throw PasswordGeneratorError.wordListUnavailable }
        return usable
    }

    /// Generates a word-based passphrase from the EFF Large Wordlist.
    /// - Throws: `PasswordGeneratorError` or the provider's error; never returns an empty value.
    func generatePassphrase(config: PasswordGeneratorConfig, provider: RandomnessProvider) throws -> String {
        let wordCount = PasswordGeneratorConfig.clampedWordCount(config.wordCount)
        let list = try wordList()
        var words: [String] = []
        for _ in 0..<wordCount {
            var word = list[try Self.uniformIndex(below: list.count, using: provider)]
            if config.capitalize {
                word = word.prefix(1).uppercased() + word.dropFirst()
            }
            words.append(word)
        }
        if config.includeNumber {
            let wordIndex = try Self.uniformIndex(below: words.count, using: provider)
            let digit = try Self.uniformIndex(below: 10, using: provider)
            words[wordIndex] += String(digit)
        }
        return words.joined(separator: config.separator)
    }
}
