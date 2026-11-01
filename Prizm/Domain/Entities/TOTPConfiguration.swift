import Foundation

// MARK: - TOTPHashAlgorithm

/// HMAC hash used to derive a time-based one-time password.
///
/// RFC 6238 §1.2 allows HMAC-SHA-1, HMAC-SHA-256 and HMAC-SHA-512. SHA-1 is the default
/// because nearly every service issues SHA-1 seeds. The Domain layer only *names* the
/// algorithm; the Data layer maps it to CryptoKit (Constitution §II, §III).
nonisolated enum TOTPHashAlgorithm: Equatable, Hashable {
    case sha1
    case sha256
    case sha512
}

// MARK: - TOTPError

/// Reasons a stored seed cannot produce a code.
///
/// Security: no case carries an associated value, so a seed can never leak into a log
/// line or error description through this type (Constitution §III, §V).
nonisolated enum TOTPError: Error, Equatable {
    /// The seed is empty or only whitespace.
    case emptySeed
    /// The secret is missing or decodes to zero bytes (fewer than 8 bits of base32).
    case invalidSecret
    /// A seed that never gives a valid time-based code: `otpauth://hotp` (totp-parity, design D2).
    case unsupportedScheme
    /// `digits=0`, which can never give a valid code (totp-parity, design D2).
    case unsupportedParameter
}

// MARK: - TOTPAlphabet

/// How the truncated value becomes the shown code.
nonisolated enum TOTPAlphabet: Equatable, Hashable {
    /// `value % 10^digits`, zero-padded (RFC 4226 §5.3).
    case decimal
    /// Steam Guard: five characters of `23456789BCDFGHJKMNPQRTVWXY`, least significant first, as
    /// the Bitwarden SDK's `derive_steam_otp` (sdk-internal `c1c9b9a5`, `totp.rs:322-336`).
    case steam
}

// MARK: - TOTPConfiguration

/// The parsed form of a stored TOTP seed.
///
/// Built only by `TOTPSeedParser.parse(_:)`. It is parsed per refresh pass and dropped, so no
/// extra copy of the secret outlives the pass (see data-model.md).
nonisolated struct TOTPConfiguration: Equatable {
    /// Decoded base32 bytes. Must be non-empty.
    let secret: Data
    let algorithm: TOTPHashAlgorithm
    /// 1 to 10, as the Bitwarden SDK clamps it (RFC 4226 §5.3 asks for at least 6; official apps
    /// accept fewer, and so does Prizm, totp-parity D1). Default 6; 5 characters for Steam.
    let digits: Int
    /// Validity period in seconds, at least 1. Default 30 (RFC 6238 §4.1).
    let period: Int
    var alphabet: TOTPAlphabet = .decimal
}
