import Foundation
import CommonCrypto
import CryptoKit
import os.log

// MARK: - AttachmentCryptoError

/// Errors thrown by attachment cryptographic operations.
nonisolated enum AttachmentCryptoError: Error, Equatable {
    /// The blob's length matches neither supported layout (`AttachmentBlobLayout`).
    case malformedBlob
    /// The blob is an EncArrayBuffer of a type Prizm does not decrypt: type 0 (AES-CBC without a
    /// MAC, refused by the official clients too) or an unknown type byte.
    case unsupportedEncryptionType
    /// HMAC-SHA256 verification failed — blob may have been tampered with.
    case macMismatch
    /// AES-256-CBC decryption failed.
    case decryptionFailed
    /// AES-256-CBC encryption or IV generation failed.
    case encryptionFailed
    /// `SecRandomCopyBytes` failed to generate a random key.
    case keyGenerationFailed
    /// The attachment key data is not 64 bytes (encKey ‖ macKey).
    case invalidKeyLength
}

// MARK: - AttachmentBlobLayout

/// The two attachment file layouts Prizm reads (openspec change fix-attachment-file-format, D2).
///
/// - `official`: the EncArrayBuffer every Bitwarden client writes, `0x02 ‖ IV(16) ‖ MAC(32) ‖
///   ciphertext`. Sources: SDK `crates/bitwarden-crypto/src/enc_string/symmetric.rs`
///   (`from_buffer`, `to_buffer`), TS `clients/libs/legacy-crypto/src/models/enc-array-buffer.ts`.
/// - `legacyPrizm`: `IV(16) ‖ ciphertext ‖ MAC(32)`, written by Prizm 1.1.0 to 1.5.x only. Still
///   read, so those files stay readable and can be converted.
///
/// Detection by structure, never by trial decryption: AES-CBC with PKCS#7 always yields a
/// positive multiple of 16 bytes, so an official blob is `49 + 16k` bytes (`L mod 16 == 1`) and an
/// old one `48 + 16k` (`L mod 16 == 0`). Byte 0 alone would not do: an old blob starts with a
/// random IV byte, which is `0x02` for about 1 in 256 files.
nonisolated enum AttachmentBlobLayout: Equatable, Sendable {
    case official
    case legacyPrizm

    /// The EncArrayBuffer type byte of an AES-256-CBC + HMAC-SHA256 blob.
    static let aesCbcHmacType: UInt8 = 0x02
    /// The EncArrayBuffer type byte of AES-256-CBC without a MAC.
    static let aesCbcType: UInt8 = 0x00

    /// - Throws: `AttachmentCryptoError.unsupportedEncryptionType` for type 0 or another type byte
    ///   on an official-length blob; `.malformedBlob` for any other length.
    static func of(_ blob: Data) throws -> AttachmentBlobLayout {
        let length = blob.count
        switch length % 16 {
        case 1:
            guard let type = blob.first else { throw AttachmentCryptoError.malformedBlob }
            guard type == aesCbcHmacType else { throw AttachmentCryptoError.unsupportedEncryptionType }
            // type(1) + IV(16) + MAC(32) + at least one block (16).
            guard length >= 65 else { throw AttachmentCryptoError.malformedBlob }
            return .official
        case 0 where length >= 64:
            // IV(16) + at least one block (16) + MAC(32).
            return .legacyPrizm
        default:
            throw AttachmentCryptoError.malformedBlob
        }
    }
}

// MARK: - Attachment crypto extension on PrizmCryptoServiceImpl

/// Concrete implementations of the six attachment-crypto requirements declared on
/// `PrizmCryptoService` (see `PrizmCryptoService.swift`), in an extension on
/// `PrizmCryptoServiceImpl`. The AES-CBC work goes through `EncString`'s guarded helpers.
///
/// All new methods are `nonisolated` so they can be called from any concurrency context
/// without hopping onto the actor — they access no actor-isolated state.
///
/// Binary blob format: the official EncArrayBuffer type 2, `0x02 ‖ IV(16) ‖ HMAC-SHA256(32) ‖
/// ciphertext` (see `AttachmentBlobLayout`). Prizm 1.1.0 to 1.5.x wrote `IV ‖ ciphertext ‖ HMAC`
/// instead, claiming wrongly that this was the whitepaper format (fix-attachment-file-format);
/// those files are still read. In both layouts the HMAC is computed over `IV ‖ ciphertext`
/// (Encrypt-then-MAC) and verified before decryption to prevent padding-oracle attacks
/// (Vaudenay, 2002).
extension PrizmCryptoServiceImpl {

    private static let logger = Logger(subsystem: "com.prizm", category: "attachments")

    // MARK: - 2.1 generateAttachmentKey

    /// Generates a cryptographically random 64-byte per-attachment key.
    ///
    /// - Security goal: each file upload gets an independent random key so that
    ///   compromise of one attachment key does not compromise any other attachment
    ///   (key isolation per Bitwarden Security Whitepaper §4).
    /// - Algorithm: 64 bytes from `SecRandomCopyBytes` (backed by `/dev/urandom`).
    ///   First 32 bytes = AES-256-CBC encryption key; last 32 bytes = HMAC-SHA256 MAC key.
    /// - Spec: Bitwarden Security Whitepaper §4 — "Attachment Key Generation".
    ///
    /// - Returns: 64-byte random key Data.
    /// - Throws: `AttachmentCryptoError.keyGenerationFailed` if `SecRandomCopyBytes` fails.
    nonisolated func generateAttachmentKey() throws -> Data {
        var keyBytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, 64, &keyBytes)
        guard status == errSecSuccess else {
            Self.logger.error("SecRandomCopyBytes failed generating attachment key (OSStatus \(status))")
            throw AttachmentCryptoError.keyGenerationFailed
        }
        return Data(keyBytes)
    }

    // MARK: - 2.2 encryptData

    /// Encrypts file data using AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC).
    ///
    /// - Security goal: confidentiality and integrity of attachment file bytes.
    ///   The HMAC covers the IV and ciphertext so that any bit-flip in the blob is
    ///   detected before decryption (prevents padding-oracle attacks).
    ///
    /// - Algorithm: AES-256-CBC per NIST SP 800-38A; HMAC-SHA256 per RFC 2104.
    ///   Key split: `attachmentKey[0..<32]` = AES key; `attachmentKey[32..<64]` = MAC key.
    ///
    /// - Binary layout: `0x02 ‖ IV (16 bytes) ‖ HMAC-SHA256 (32 bytes) ‖ ciphertext`, the official
    ///   EncArrayBuffer (SDK `bitwarden-crypto/src/enc_string/symmetric.rs`, `to_buffer`), so every
    ///   Bitwarden client can open the file.
    ///
    /// - Parameters:
    ///   - data:          Plaintext file bytes.
    ///   - attachmentKey: 64-byte per-attachment key (encKey ‖ macKey).
    /// - Returns: Binary encrypted blob.
    /// - Throws: `AttachmentCryptoError.invalidKeyLength` if key is not 64 bytes.
    /// - Throws: `AttachmentCryptoError.encryptionFailed` on AES failure.
    nonisolated func encryptData(_ data: Data, attachmentKey: Data) throws -> Data {
        guard attachmentKey.count == 64 else {
            throw AttachmentCryptoError.invalidKeyLength
        }
        let encKey = attachmentKey[0..<32]
        let macKey = attachmentKey[32..<64]

        // Random IV — 16 bytes per AES-CBC block size (NIST SP 800-38A).
        var ivBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &ivBytes) == errSecSuccess else {
            throw AttachmentCryptoError.encryptionFailed
        }
        let iv = Data(ivBytes)

        let ciphertext = try aesCbcEncrypt(key: encKey, iv: iv, plaintext: data)

        // HMAC over IV ‖ ciphertext (Encrypt-then-MAC per Bitwarden Security Whitepaper §4).
        let mac = try CryptoKeys.hmacSHA256(key: macKey, data: iv + ciphertext)

        // Layout: type (1) ‖ IV (16) ‖ HMAC (32) ‖ ciphertext
        return Data([AttachmentBlobLayout.aesCbcHmacType]) + iv + mac + ciphertext
    }

    // MARK: - 2.3 decryptData

    /// Decrypts an attachment file in the official layout or in Prizm's old layout.
    ///
    /// - Security goal: integrity and confidentiality. HMAC verification happens
    ///   BEFORE decryption (Encrypt-then-MAC) to prevent padding-oracle attacks.
    ///
    /// - Algorithm: AES-256-CBC per NIST SP 800-38A; HMAC-SHA256 per RFC 2104.
    ///
    /// - Layout: chosen by `AttachmentBlobLayout.of` from length and type byte; the MAC then
    ///   confirms it, since a blob written in the other layout fails the MAC.
    /// - Intentionally NOT done: decrypting type 0 (no MAC). The official clients refuse it too
    ///   (SDK `symmetric.rs`, `DecryptionNotImplementedForKey`; TS `decryptFileData`), and without
    ///   a MAC nothing authenticates the bytes before they reach AES-CBC.
    /// - Why the old layout is still read: only Prizm wrote it, so without this the user's own
    ///   files would be unreadable everywhere, and they could not be converted.
    ///
    /// - Parameters:
    ///   - data:          Encrypted binary blob.
    ///   - attachmentKey: 64-byte per-attachment key (encKey ‖ macKey).
    /// - Returns: Plaintext file bytes.
    /// - Throws: `AttachmentCryptoError.malformedBlob` or `.unsupportedEncryptionType` (see
    ///   `AttachmentBlobLayout.of`), `.macMismatch` if HMAC verification fails,
    ///   `.invalidKeyLength` if key is not 64 bytes, `.decryptionFailed` on AES failure.
    nonisolated func decryptData(_ data: Data, attachmentKey: Data) throws -> Data {
        guard attachmentKey.count == 64 else {
            throw AttachmentCryptoError.invalidKeyLength
        }
        let layout: AttachmentBlobLayout
        do {
            layout = try AttachmentBlobLayout.of(data)
        } catch {
            Self.logger.error("Attachment blob not decrypted: \(ErrorLog.describe(error), privacy: .public), \(data.count, privacy: .public) bytes")
            throw error
        }

        let encKey = attachmentKey[attachmentKey.startIndex..<attachmentKey.startIndex.advanced(by: 32)]
        let macKey = attachmentKey[attachmentKey.startIndex.advanced(by: 32)..<attachmentKey.endIndex]

        let start = data.startIndex
        let iv, mac, ciphertext: Data
        switch layout {
        case .official:
            iv         = data[start.advanced(by: 1)..<start.advanced(by: 17)]
            mac        = data[start.advanced(by: 17)..<start.advanced(by: 49)]
            ciphertext = data[start.advanced(by: 49)..<data.endIndex]
        case .legacyPrizm:
            Self.logger.info("Attachment blob in Prizm's old layout read")
            iv         = data[start..<start.advanced(by: 16)]
            mac        = data[data.endIndex.advanced(by: -32)..<data.endIndex]
            ciphertext = data[start.advanced(by: 16)..<data.endIndex.advanced(by: -32)]
        }

        // Verify HMAC over IV ‖ ciphertext before decrypting (Encrypt-then-MAC).
        guard CryptoKeys.verifyHmacSHA256(key: macKey, data: iv + ciphertext, expected: mac) else {
            Self.logger.error("Attachment blob MAC verification failed — blob may be corrupt or tampered")
            throw AttachmentCryptoError.macMismatch
        }

        return try aesCbcDecrypt(key: encKey, iv: iv, ciphertext: ciphertext)
    }

    // MARK: - 2.4 encryptAttachmentKey

    /// Wraps the per-attachment key as a type-2 EncString using the cipher's `CryptoKeys`.
    ///
    /// - Security goal: the attachment key is encrypted with the cipher's effective key
    ///   so it can be stored server-side and decrypted only by someone who holds the
    ///   cipher key (which itself is encrypted with the vault key).
    ///   This implements the Bitwarden two-layer key scheme per Security Whitepaper §4.
    ///
    /// - Algorithm: EncString type-2 (AES-256-CBC + HMAC-SHA256) matching all other
    ///   Bitwarden field encryption. Uses `cipherKey.encryptionKey` for AES-CBC and
    ///   `cipherKey.macKey` for HMAC-SHA256.
    ///
    /// - Spec: Bitwarden Security Whitepaper §4, "Cipher String Types".
    ///
    /// - Parameters:
    ///   - key:       Raw 64-byte per-attachment key to wrap.
    ///   - cipherKey: The cipher's effective `CryptoKeys` (from `VaultKeyService`).
    /// - Returns: EncString wire representation (e.g. `"2.<iv>|<ct>|<mac>"`).
    /// - Throws: `EncStringError.encryptionFailed` on AES or IV generation failure.
    nonisolated func encryptAttachmentKey(_ key: Data, cipherKey: CryptoKeys) throws -> String {
        return try EncString.encrypt(data: key, keys: cipherKey).toString()
    }

    // MARK: - 2.5 decryptAttachmentKey

    /// Unwraps a per-attachment key from its EncString representation.
    ///
    /// - Security goal: recovers the 64-byte per-attachment key needed to decrypt the
    ///   file blob. The EncString is the value stored in `Attachment.encryptedKey`.
    ///
    /// - Algorithm: EncString type-2 (AES-256-CBC + HMAC-SHA256). MAC is verified before
    ///   decryption (Encrypt-then-MAC). Bitwarden Security Whitepaper §4.
    ///
    /// - Parameters:
    ///   - encString: The EncString wire representation of the attachment key.
    ///   - cipherKey: The cipher's effective `CryptoKeys`.
    /// - Returns: Raw 64-byte attachment key Data.
    /// - Throws: `EncStringError` on parse or decryption failure.
    nonisolated func decryptAttachmentKey(_ encString: String, cipherKey: CryptoKeys) throws -> Data {
        let enc = try EncString(string: encString)
        return try enc.decrypt(keys: cipherKey)
    }

    // MARK: - 2.6 encryptFileName

    /// Encrypts a plaintext file name as a type-2 EncString for upload metadata.
    ///
    /// - Security goal: file names can reveal sensitive information (e.g. "salary_2025.pdf",
    ///   "diagnosis_report.docx"). Encrypting them before upload prevents the server from
    ///   learning the file names of user attachments.
    ///
    /// - Algorithm: EncString type-2 (AES-256-CBC + HMAC-SHA256). Uses
    ///   `cipherKey.encryptionKey` for AES and `cipherKey.macKey` for HMAC.
    ///   Matches `CipherMapper.encryptString` for consistency.
    ///
    /// - Parameters:
    ///   - name:      Plaintext file name.
    ///   - cipherKey: The cipher's effective `CryptoKeys`.
    /// - Returns: EncString wire representation.
    /// - Throws: `EncStringError.encryptionFailed` on failure.
    nonisolated func encryptFileName(_ name: String, cipherKey: CryptoKeys) throws -> String {
        guard let nameData = name.data(using: .utf8) else {
            throw EncStringError.encryptionFailed
        }
        return try EncString.encrypt(data: nameData, keys: cipherKey).toString()
    }

    // MARK: - Private CommonCrypto helpers (AES-256-CBC)

    // One guarded CommonCrypto implementation for EncStrings and blobs (fix-encstring-validation,
    // D3): `EncString`'s helpers refuse an IV that is not 16 bytes or a key that is not 32 bytes.
    // Their errors become this file's own, which the attachment flow maps to its messages.

    nonisolated private func aesCbcEncrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
        do {
            return try EncString.aesCbcEncrypt(key: key, iv: iv, plaintext: plaintext)
        } catch {
            // Logged before the mapping, so the cause is not lost (§V; code review 2026-10-30).
            Self.logger.error("Attachment AES-CBC encryption failed: \(ErrorLog.describe(error), privacy: .public)")
            throw AttachmentCryptoError.encryptionFailed
        }
    }

    nonisolated private func aesCbcDecrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
        do {
            return try EncString.aesCbcDecrypt(key: key, iv: iv, ciphertext: ciphertext)
        } catch {
            Self.logger.error("Attachment AES-CBC decryption failed after a valid MAC: \(ErrorLog.describe(error), privacy: .public)")
            throw AttachmentCryptoError.decryptionFailed
        }
    }
}
