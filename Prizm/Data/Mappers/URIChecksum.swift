import Foundation
import CryptoKit

/// The read-side check of a login website's `uriChecksum` (openspec change `uri-checksum-validation`).
///
/// - Security goal: a server that adds a website to an item, or swaps one website's ciphertext for
///   another's, cannot make the item show or match an address its owner never saved. Without the
///   check, a later AutoFill would offer the credentials on the attacker's site.
/// - Algorithm: the decrypted checksum must be the standard, padded base64 (RFC 4648 section 4) of
///   SHA-256 (FIPS 180-4) over the address's exact UTF-8 bytes; the digests are compared in constant
///   time. Same predicate as `is_checksum_valid` in the Bitwarden SDK (`bitwarden-vault`,
///   `login.rs`), which uses `subtle::ConstantTimeEq`.
/// - Deviation: none.
/// - Intentionally NOT done: no normalisation of the address (the hash covers what is encrypted as
///   `uri`, as on the write side, `CipherMapper.uriChecksumPlaintext`). Which items are checked is
///   the caller's decision (`CipherMapper.mapLogin`: only items with their own key, as in the SDK).
nonisolated enum URIChecksum {

    /// True when both values are present and `checksumPlaintext` is the base64 SHA-256 of `uri`.
    static func isValid(uri: String?, checksumPlaintext: String?) -> Bool {
        guard let uri, let checksumPlaintext,
              let expected = Data(base64Encoded: checksumPlaintext),
              // Foundation also accepts base64 whose unused padding bits are set; the SDK's standard
              // engine refuses it, so only the canonical spelling counts.
              expected.base64EncodedString() == checksumPlaintext else { return false }
        let actual = Data(SHA256.hash(data: Data(uri.utf8)))
        return constantTimeEqual(expected, actual)
    }

    /// Compares every byte regardless of where the first difference is. A length difference returns
    /// early: the length of a SHA-256 digest is public.
    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}
