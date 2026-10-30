import Foundation

/// The strength of what the password generator produces with given settings, in bits of entropy
/// (openspec change `generator-strength-meter`).
///
/// Computed from the settings, not guessed from the text: the generator picks every character and
/// word uniformly (`PasswordGenerator.uniformIndex`), so the output space is known.
/// - Password: log2 of the number of passwords the settings allow: every string of the effective
///   length over the enabled sets that holds at least each set's minimum (design D1). The generator
///   is not exactly uniform over them (required characters come first, then the shuffle), so the
///   real entropy is slightly lower; the tooltip says so.
/// - Passphrase: `wordCount × log2(listSize)`, plus `log2(10) + log2(wordCount)` for the digit and
///   the word it is appended to. Capitalizing and the separator are fixed and add nothing.
struct GeneratorStrength: Equatable {

    /// Category boundaries in bits (Christian, 2026-10-30). 64 bits is within reach of an offline
    /// attack on a fast hash; 128 bits is the AES-128 security level.
    enum Threshold {
        static let ok: Double = 64
        static let strong: Double = 80
        static let veryStrong: Double = 128
    }

    enum Category: Equatable {
        case weak, ok, strong, veryStrong

        init(bits: Double) {
            switch bits {
            case ..<Threshold.ok:         self = .weak
            case ..<Threshold.strong:     self = .ok
            case ..<Threshold.veryStrong: self = .strong
            default:                      self = .veryStrong
            }
        }

        var name: String {
            switch self {
            case .weak:       return "Weak"
            case .ok:         return "OK"
            case .strong:     return "Strong"
            case .veryStrong: return "Very strong"
            }
        }
    }

    let bits: Double
    let category: Category

    init(bits: Double) {
        self.bits = bits
        self.category = Category(bits: bits)
    }

    static func of(_ config: PasswordGeneratorConfig, wordListSize: Int) -> GeneratorStrength {
        switch config.mode {
        case .password:
            let sets = PasswordGenerator.characterSets(config).map { (size: $0.chars.count, minimum: $0.minimum) }
            return GeneratorStrength(bits: passwordSpaceBits(length: config.effectiveLength, sets: sets))
        case .passphrase:
            let words = PasswordGeneratorConfig.clampedWordCount(config.wordCount)
            var bits = Double(words) * log2(Double(wordListSize))
            if config.includeNumber { bits += log2(10) + log2(Double(words)) }
            return GeneratorStrength(bits: bits)
        }
    }

    /// log2 of the number of strings of `length` over disjoint sets in which set `i` occurs at least
    /// `minimum` times: the sum over the counts `k_i` (each ≥ its minimum, together `length`) of
    /// `length! / ∏ k_i! × ∏ size_i^k_i`. Summed in log space (the count exceeds `Double` for long
    /// passwords): a dynamic program over the sets, at most 5 × 129 × 129 steps.
    static func passwordSpaceBits(length: Int, sets: [(size: Int, minimum: Int)]) -> Double {
        // terms[n] = ln of the sum, over the sets handled so far using n positions, of ∏ size^k / k!
        var terms = [Double](repeating: -.infinity, count: length + 1)
        terms[0] = 0
        for set in sets {
            let lnSize = log(Double(set.size))
            var next = [Double](repeating: -.infinity, count: length + 1)
            for used in 0...length where terms[used] > -.infinity {
                for k in set.minimum...max(set.minimum, length - used) where used + k <= length {
                    let term = terms[used] + Double(k) * lnSize - lgamma(Double(k + 1))
                    next[used + k] = logSumExp(next[used + k], term)
                }
            }
            terms = next
        }
        return (lgamma(Double(length + 1)) + terms[length]) / log(2)
    }

    private static func logSumExp(_ a: Double, _ b: Double) -> Double {
        if a == -.infinity { return b }
        if b == -.infinity { return a }
        let high = max(a, b)
        return high + log(exp(a - high) + exp(b - high))
    }

    /// Whole bits, rounded down, so the meter never claims more than the settings give.
    var wholeBits: Int { Int(bits.rounded(.down)) }

    /// "Strong · 97 bits"
    var label: String { "\(category.name) · \(wholeBits) bits" }

    /// "Strong, 97 bits", for VoiceOver.
    var accessibilityValue: String { "\(category.name), \(wholeBits) bits" }

    /// The bar's filled share: full from 128 bits.
    var fill: Double { min(bits / Threshold.veryStrong, 1) }

    /// Where an OK value sits between orange (0, at 64 bits) and yellow (1, towards 80 bits).
    var okProgress: Double {
        min(max((bits - Threshold.ok) / (Threshold.strong - Threshold.ok), 0), 1)
    }
}
