import Foundation

/// Turns a stored TOTP seed into a `TOTPConfiguration`, accepting the same forms as the Bitwarden
/// SDK (`totp.rs` `FromStr`, sdk-internal `c1c9b9a5`), so a seed that shows a code in official
/// apps shows the same code here (openspec change `totp-parity`, design D1):
/// - `otpauth://` (any case) with any host but `hotp`: `secret`, `algorithm`, `digits`, `period`;
/// - `steam://<secret>`: Steam Guard, five characters, 30 s;
/// - anything else, other schemes included: the whole string is the secret.
///
/// Secrets keep only the base32 letters after upper-casing, as the SDK's `decode_b32`. Recorded
/// differences (design D2): `otpauth://hotp`, a secret of fewer than 8 bits and `digits=0` are
/// unavailable instead of giving a code that can never be right, and surrounding whitespace is
/// trimmed.
///
/// Base32 decoding is an encoding, not cryptography, so it lives in the Domain layer
/// (Constitution §II). The seed is never logged or placed in an error (Constitution §III, §V).
nonisolated enum TOTPSeedParser {

    static func parse(_ seed: String) throws -> TOTPConfiguration {
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TOTPError.emptySeed }
        // The SDK lowercases the whole key first; parameter names and values compare in lowercase.
        let key = trimmed.lowercased()

        if key.hasPrefix(uriPrefix) {
            return try parseKeyURI(String(key.dropFirst(uriPrefix.count)))
        }
        if key.hasPrefix(steamPrefix) {
            return TOTPConfiguration(secret: try decodeBase32(String(key.dropFirst(steamPrefix.count))),
                                     algorithm: .sha1, digits: steamDigits, period: defaultPeriod, alphabet: .steam)
        }
        return TOTPConfiguration(secret: try decodeBase32(key), algorithm: .sha1,
                                 digits: defaultDigits, period: defaultPeriod)
    }

    // MARK: - Defaults (RFC 6238 §4.1, RFC 4226 §5.3; SDK `totp.rs:23-28`)

    private static let uriPrefix = "otpauth://"
    private static let steamPrefix = "steam://"
    private static let defaultDigits = 6
    private static let defaultPeriod = 30
    private static let steamDigits = 5
    private static let maxDigits = 10

    // MARK: - otpauth:// links

    /// `rest` is the link after `otpauth://`, lowercased. Parsed like the SDK's WHATWG `Url::parse`
    /// plus form-urlencoded `query_pairs`, not `URLComponents`, which refuses a label with a raw
    /// space and keeps the first of two equal keys.
    private static func parseKeyURI(_ rest: String) throws -> TOTPConfiguration {
        let beforeFragment = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = beforeFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        // The host as WHATWG reads it: the authority up to the first "/", without "userinfo@" and
        // without ":port".
        let authority = parts[0].prefix { $0 != "/" }
        let host = authority.split(separator: "@", omittingEmptySubsequences: false).last!
            .prefix { $0 != ":" }
        // A counter-based seed: a time-based code for it is always wrong (design D2).
        guard host != "hotp" else { throw TOTPError.unsupportedScheme }

        var parameters: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") where !pair.isEmpty {
                let nameAndValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                // The last of two equal keys wins, as the SDK's `HashMap` (totp.rs:201).
                parameters[formDecoded(nameAndValue[0])] = nameAndValue.count > 1 ? formDecoded(nameAndValue[1]) : ""
            }
        }

        guard let rawSecret = parameters["secret"] else { throw TOTPError.invalidSecret }
        let algorithm: TOTPHashAlgorithm
        // Lowercased again: a percent escape can spell a capital the first lowercasing missed.
        switch parameters["algorithm"]?.lowercased() {
        case "sha256": algorithm = .sha256
        case "sha512": algorithm = .sha512
        default:       algorithm = .sha1
        }
        let digits = min(maxDigits, unsigned32(parameters["digits"]).map(Int.init) ?? defaultDigits)
        guard digits > 0 else { throw TOTPError.unsupportedParameter }
        let period = max(1, unsigned32(parameters["period"]).map(Int.init) ?? defaultPeriod)

        return TOTPConfiguration(secret: try decodeBase32(rawSecret), algorithm: algorithm,
                                 digits: digits, period: period)
    }

    /// `application/x-www-form-urlencoded` decoding as WHATWG (the SDK's `query_pairs`): `+` is a
    /// space; each valid `%HH` becomes its byte and an invalid escape stays as written; the bytes
    /// are then read as UTF-8 with invalid sequences replaced by U+FFFD.
    private static func formDecoded(_ text: Substring) -> String {
        let input = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " "))
            } else if byte == UInt8(ascii: "%"), index + 2 < input.count,
                      let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                bytes.append(high << 4 | low)
                index += 2
            } else {
                bytes.append(byte)
            }
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Rust's `u32::from_str`: an optional leading `+`, then ASCII digits only, at most
    /// 4 294 967 295; anything else (negative numbers among them) is nil and the default applies.
    private static func unsigned32(_ text: String?) -> UInt32? {
        guard var text else { return nil }
        if text.hasPrefix("+") { text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt32(text)
    }

    // MARK: - Base32 (RFC 4648 §6, SDK `decode_b32`)

    private static let base32Alphabet: [Unicode.Scalar: UInt8] = {
        var table: [Unicode.Scalar: UInt8] = [:]
        for (index, scalar) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".unicodeScalars.enumerated() {
            table[scalar] = UInt8(index)
        }
        return table
    }()

    /// Upper-cases, keeps the base32 letters (by Unicode scalar, as the SDK iterates `char`s) and
    /// decodes them in exact 8-bit chunks; leftover bits are dropped. Zero bytes is an error here
    /// (design D2): the SDK would compute a code from an empty key.
    private static func decodeBase32(_ text: String) throws -> Data {
        var output = Data()
        var buffer: UInt32 = 0
        var bitCount = 0
        for scalar in text.uppercased().unicodeScalars {
            guard let value = base32Alphabet[scalar] else { continue }
            buffer = (buffer << 5) | UInt32(value)
            bitCount += 5
            if bitCount >= 8 {
                output.append(UInt8((buffer >> UInt32(bitCount - 8)) & 0xFF))
                bitCount -= 8
            }
        }
        guard !output.isEmpty else { throw TOTPError.invalidSecret }
        return output
    }
}
