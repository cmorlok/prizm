import Foundation
import CommonCrypto
import CryptoKit

// MARK: - EncType

/// The symmetric types of a Bitwarden EncString, numbered as the wire prefix.
///
/// Names and numbers as in the official enum (`clients/libs/legacy-crypto/src/enums/
/// encryption-type.enum.ts:3-18`). The RSA types 3–6 "never occur in the same places that the
/// symmetric ones would"; they are `AsymmetricEncType` and only organization keys use them
/// (fix-encstring-validation, D2). Type 1 was removed from Bitwarden.
nonisolated enum EncType: Int {
    /// Type 0 `AesCbc256_B64`: AES-256-CBC without a MAC. Parsed so the error is precise and a
    /// stored type-0 name can be recognised, but never decrypted (D1).
    case aes256Cbc_B64             = 0
    /// Type 2 `AesCbc256_HmacSha256_B64`: AES-256-CBC + HMAC-SHA256, `iv|ct|mac`. The only type
    /// Prizm decrypts.
    case aes256Cbc_HmacSha256_B64  = 2
}

/// The RSA types of a Bitwarden EncString (`encryption-type.enum.ts:3-18`), used only for wrapped
/// organization keys (`PrizmCryptoServiceImpl.unwrapOrgKey`, D4). Prizm unwraps type 4 only.
nonisolated enum AsymmetricEncType: Int {
    /// Type 3 `Rsa2048_OaepSha256_B64`.
    case rsa2048OaepSha256_B64            = 3
    /// Type 4 `Rsa2048_OaepSha1_B64`: what current clients write for organization keys.
    case rsa2048OaepSha1_B64              = 4
    /// Type 5 `Rsa2048_OaepSha256_HmacSha256_B64`.
    case rsa2048OaepSha256_HmacSha256_B64 = 5
    /// Type 6 `Rsa2048_OaepSha1_HmacSha256_B64`.
    case rsa2048OaepSha1_HmacSha256_B64   = 6
}

// MARK: - EncStringError

/// Errors that can be thrown by EncString operations.
nonisolated enum EncStringError: Error, Equatable {
    /// The string does not conform to the "<type>.<segments>" format.
    case malformedEncString
    /// The type is not a symmetric one Prizm parses (0, 2), or is type 0, which is never decrypted.
    case unsupportedEncType
    /// HMAC-SHA256 verification failed — ciphertext may have been tampered with.
    case macMismatch
    /// AES decryption failed (CommonCrypto returned an error status).
    case decryptionFailed
    /// AES encryption or IV generation failed.
    case encryptionFailed
    /// The IV is not 16 bytes.
    case invalidIVLength
}

// MARK: - EncString

/// A parsed symmetric Bitwarden EncString.
///
/// The wire format is `<type>.<iv_b64>|<ct_b64>[|<mac_b64>]`. Parsing is at least as strict as the
/// SDK's (`bitwarden-crypto/src/enc_string/symmetric.rs:139-155`, `mod.rs:36-43`); only type 2 is
/// ever decrypted (fix-encstring-validation, D1–D3).
nonisolated struct EncString {

    let encType:    EncType
    let iv:         Data
    let ciphertext: Data
    /// Present only for type 2.
    let mac:        Data?

    /// Byte lengths fixed by the format.
    enum Length {
        static let iv  = kCCBlockSizeAES128
        static let mac = 32
        static let key = kCCKeySizeAES256
    }

    // MARK: - Parsing

    /// Parses a Bitwarden EncString from its wire representation.
    ///
    /// - Throws: `EncStringError.unsupportedEncType` for any type other than 0 and 2 (the RSA types
    ///   3–6, COSE type 7, unknown numbers).
    /// - Throws: `EncStringError.invalidIVLength` when the IV does not decode to 16 bytes.
    /// - Throws: `EncStringError.malformedEncString` for a wrong part count, bad Base64, a MAC that
    ///   is not 32 bytes, or a type-2 ciphertext that is empty or not a multiple of 16 bytes.
    init(string: String) throws {
        guard let (typeInt, body) = Self.splitHeader(string) else {
            throw EncStringError.malformedEncString
        }
        guard let type = EncType(rawValue: typeInt) else {
            throw EncStringError.unsupportedEncType
        }
        let parts = body.split(separator: "|", omittingEmptySubsequences: false)
            .map { Data(base64Encoded: String($0)) }
        guard parts.count == (type == .aes256Cbc_HmacSha256_B64 ? 3 : 2),
              let iv = parts[0], let ciphertext = parts[1] else {
            throw EncStringError.malformedEncString
        }
        guard iv.count == Length.iv else { throw EncStringError.invalidIVLength }

        self.encType    = type
        self.iv         = iv
        self.ciphertext = ciphertext
        switch type {
        case .aes256Cbc_B64:
            self.mac = nil
        case .aes256Cbc_HmacSha256_B64:
            guard let mac = parts[2], mac.count == Length.mac,
                  !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
                throw EncStringError.malformedEncString
            }
            self.mac = mac
        }
    }

    /// Splits `<type>.<body>` and returns the type number and the body, or `nil` when there is no
    /// dot or the type is not a plain decimal number. The one header parser for symmetric and RSA
    /// EncStrings (code review 2026-10-30).
    ///
    /// The type must be ASCII digits without sign or leading zero, as the SDK matches the literal
    /// header (`"2"`, `"4"`); `Int(_:)` alone would also take `+2` or `02`.
    static func splitHeader(_ string: String) -> (type: Int, body: Substring)? {
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let header = string[..<dot]
        guard !header.isEmpty, header.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              header == "0" || header.first != "0", let type = Int(header) else { return nil }
        return (type, string[string.index(after: dot)...])
    }

    // MARK: - Serialise

    /// Returns the wire-format string representation.
    func toString() -> String {
        let ivB64 = iv.base64EncodedString()
        let ctB64 = ciphertext.base64EncodedString()
        if let mac = mac {
            return "\(encType.rawValue).\(ivB64)|\(ctB64)|\(mac.base64EncodedString())"
        }
        return "\(encType.rawValue).\(ivB64)|\(ctB64)"
    }

    // MARK: - Decryption

    /// Decrypts a type-2 EncString: verifies the HMAC-SHA256 over `iv || ciphertext` with the MAC
    /// key, then decrypts AES-256-CBC with PKCS#7 padding.
    ///
    /// - Security goal: no AES-CBC decryption of data that is not authenticated. A server (or anyone
    ///   who can change stored data) could otherwise rewrite `2.iv|ct|mac` as `0.iv|ct`, flip
    ///   ciphertext bits, and have the altered plaintext shown, or use decryption errors as a padding
    ///   oracle (Vaudenay 2002). The MAC is checked first and in constant time (Encrypt-then-MAC).
    /// - Algorithm: as the SDK's `decrypt_with_key` (`symmetric.rs:479-511`), which accepts only type
    ///   2 with an AES-256-CBC-HMAC key.
    /// - Intentionally NOT done: type 0 is never decrypted, even with the right key; the SDK and the
    ///   TypeScript clients refuse it too ("Decryption of AesCbc256_B64 encrypted data is disabled").
    ///   Type 7 (COSE) is not supported.
    ///
    /// - Throws: `EncStringError.unsupportedEncType` for type 0, before the key is touched.
    /// - Throws: `EncStringError.macMismatch` if the MAC does not verify.
    /// - Throws: `EncStringError.decryptionFailed` if AES decryption fails.
    func decrypt(keys: CryptoKeys) throws -> Data {
        guard encType == .aes256Cbc_HmacSha256_B64, let mac else {
            throw EncStringError.unsupportedEncType
        }
        guard CryptoKeys.verifyHmacSHA256(key: keys.macKey, data: iv + ciphertext, expected: mac) else {
            throw EncStringError.macMismatch
        }
        return try Self.aesCbcDecrypt(key: keys.encryptionKey, iv: iv, ciphertext: ciphertext)
    }

    // MARK: - Encryption

    /// Encrypts `data` as a Type-2 (AES-256-CBC + HMAC-SHA256) EncString.
    ///
    /// Generates a cryptographically random 16-byte IV using
    /// `SecRandomCopyBytes` (backed by `/dev/urandom`).
    ///
    /// - Parameters:
    ///   - data: Plaintext bytes to encrypt.
    ///   - keys: Symmetric key pair.
    /// - Returns: A new `EncString` of type `.aes256Cbc_HmacSha256_B64`.
    static func encrypt(data: Data, keys: CryptoKeys) throws -> EncString {
        // Random IV (16 bytes) — SecRandomCopyBytes is backed by /dev/urandom and is
        // the correct API for generating cryptographic IVs on Apple platforms.
        var ivBytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, 16, &ivBytes)
        guard status == errSecSuccess else {
            throw EncStringError.encryptionFailed
        }
        let iv = Data(ivBytes)

        // AES-256-CBC encrypt
        let ciphertext = try aesCbcEncrypt(key: keys.encryptionKey, iv: iv, plaintext: data)

        // Compute MAC over iv || ciphertext
        let mac = try CryptoKeys.hmacSHA256(key: keys.macKey, data: iv + ciphertext)

        return EncString(
            encType:    .aes256Cbc_HmacSha256_B64,
            iv:         iv,
            ciphertext: ciphertext,
            mac:        mac
        )
    }

    // MARK: - CommonCrypto Helpers

    /// AES-256-CBC decrypt using CommonCrypto `CCCrypt`, without authentication: callers verify a
    /// MAC first (`decrypt(keys:)`, `AttachmentBlobLayout`).
    ///
    /// CommonCrypto is a FIPS 140-2 validated cryptographic library included in macOS.
    /// Key size: 256 bits (32 bytes).  Block size / IV size: 128 bits (16 bytes).
    /// Padding: PKCS#7 (RFC 5652 §6.3).
    ///
    /// `CCCrypt` reads 16 bytes from the IV pointer and treats a NULL pointer as an all-zero IV, so
    /// the lengths are checked here as a second line of defence behind the parser (D3).
    static func aesCbcDecrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        guard iv.count == Length.iv else { throw EncStringError.invalidIVLength }
        guard key.count == Length.key else { throw EncStringError.decryptionFailed }
        var outLength = 0
        let outCapacity = ciphertext.count + kCCBlockSizeAES128
        var outData = Data(count: outCapacity)

        let status = outData.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { ctPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            ctPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw EncStringError.decryptionFailed
        }
        outData.removeSubrange(outLength...)
        return outData
    }

    /// AES-256-CBC encrypt using CommonCrypto `CCCrypt`, with the same length checks as
    /// `aesCbcDecrypt`. Callers add the MAC.
    static func aesCbcEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        guard iv.count == Length.iv else { throw EncStringError.invalidIVLength }
        guard key.count == Length.key else { throw EncStringError.encryptionFailed }
        var outLength  = 0
        let outCapacity = plaintext.count + kCCBlockSizeAES128
        var outData    = Data(count: outCapacity)

        let status = outData.withUnsafeMutableBytes { outPtr in
            plaintext.withUnsafeBytes { ptPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            ptPtr.baseAddress, plaintext.count,
                            outPtr.baseAddress, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw EncStringError.encryptionFailed
        }
        outData.removeSubrange(outLength...)
        return outData
    }
}

// MARK: - Memberwise init (private, used by encrypt)

nonisolated private extension EncString {
    init(encType: EncType, iv: Data, ciphertext: Data, mac: Data?) {
        self.encType    = encType
        self.iv         = iv
        self.ciphertext = ciphertext
        self.mac        = mac
    }
}
