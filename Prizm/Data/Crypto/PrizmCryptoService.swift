import Foundation
import CommonCrypto
import CryptoKit
import Security
import Argon2Swift
import os.log

// MARK: - PrizmCryptoServiceError

/// Errors thrown by `PrizmCryptoService` operations.
nonisolated enum PrizmCryptoServiceError: Error, Equatable {
    /// PBKDF2 or Argon2id key derivation failed.
    case kdfFailed
    /// HKDF key expansion failed.
    case hkdfFailed
    /// The encUserKey EncString could not be parsed or decrypted.
    case invalidEncUserKey
    /// The decrypted user key is not 64 bytes (encKey + macKey).
    case invalidSymmetricKeyLength
    /// The vault is locked — no key material is available.
    case vaultLocked
    /// The KDF settings are below the Bitwarden minimums (`KdfValidator`); nothing was derived.
    case insufficientKdfParameters
    /// The KDF settings are unusable (missing, zero, negative or out of range); nothing was derived.
    case invalidKdfParameters
    /// An organization key of RSA type 3, 5 or 6, which Prizm does not unwrap (only type 4;
    /// fix-encstring-validation, D4). The associated value is the type number.
    case unsupportedOrgKeyType(Int)
    /// An organization key that is not a one-part type-4 EncString with valid Base64.
    case malformedOrgKey
    /// The decrypted private key is not a well-formed PKCS#8 RSA key (D5).
    case malformedPrivateKey
    /// RSA-OAEP decryption of a type-4 organization key failed: it was not wrapped for this
    /// user's key, or it is corrupted. The user key itself is fine (code review 2026-10-30).
    case orgKeyUnwrapFailed
}

extension PrizmCryptoServiceError: LogSafeError {
    /// The case name, and for `unsupportedOrgKeyType` the type number; never key material.
    nonisolated var logDescription: String {
        switch self {
        case .unsupportedOrgKeyType(let type): return "PrizmCryptoServiceError.unsupportedOrgKeyType(\(type))"
        default: return "PrizmCryptoServiceError.\(self)"
        }
    }
}

// MARK: - PrizmCryptoService Protocol

/// Provides cryptographic operations for the Bitwarden vault:
/// key derivation, key stretching, server hash computation, and vault lock/unlock.
///
/// Implemented as an `actor` to protect the in-memory key material from data races.
/// All async methods must be called with `await`.
protocol PrizmCryptoService: Actor {

    /// Whether the vault is currently unlocked (key material is in memory).
    var isUnlocked: Bool { get }

    /// Derives a 32-byte master key from the user's email + password using the
    /// specified KDF (PBKDF2-SHA256 or Argon2id).
    ///
    /// Per the Bitwarden Security Whitepaper §4: the master key is the root secret
    /// from which all other keys are derived.  It is **never** sent to the server.
    ///
    /// - Security goal: accepting `Data` (not `String`) lets the caller zero the
    ///   password bytes after the KDF call returns, reducing the window during which
    ///   plaintext password bytes live in the heap (Constitution §III). `String` is
    ///   immutable and cannot be reliably zeroed.
    ///
    /// - Parameters:
    ///   - password: The user's master password as UTF-8 bytes.
    ///   - salt:     The master password salt: the server's `salt`, else the email. Trimmed and
    ///               lowercased here, as the Bitwarden SDK's `derive` does.
    ///   - kdf:      KDF parameters (algorithm, iterations, optional memory/parallelism). Checked by
    ///               `KdfValidator` before anything is derived.
    /// - Returns: 32-byte master key `Data`.
    /// - Throws: `insufficientKdfParameters` or `invalidKdfParameters` before deriving.
    func makeMasterKey(password: Data, salt: String, kdf: KdfParams) async throws -> Data

    /// Stretches a 32-byte master key into a 64-byte `CryptoKeys` pair using HKDF
    /// (RFC 5869) with independent "enc" and "mac" info labels.
    ///
    /// Per the Bitwarden Security Whitepaper §4: "Key Stretching" — the stretched
    /// key provides independent encryption and MAC keys so that the two operations
    /// are cryptographically separated (NIST SP 800-107 §5.3).
    ///
    /// - Parameter masterKey: 32-byte master key.
    /// - Returns: `CryptoKeys` with a 32-byte `encryptionKey` and 32-byte `macKey`.
    func stretchKey(masterKey: Data) async throws -> CryptoKeys

    /// Computes the server authentication hash sent to the identity server during login.
    ///
    /// Per the Bitwarden Security Whitepaper §4: serverHash =
    ///   PBKDF2-SHA256(masterKey, password, iterations=1, len=32), then base64-encoded.
    ///
    /// This value proves knowledge of the master password without revealing the master
    /// key itself.  The server never stores the master key or the plaintext password.
    ///
    /// - Parameters:
    ///   - masterKey: 32-byte derived master key.
    ///   - password:  The user's master password as UTF-8 bytes (used as the PBKDF2 "salt").
    /// - Returns: Base64-encoded 32-byte hash string (44 chars with padding).
    func makeServerHash(masterKey: Data, password: Data) async throws -> String

    /// Decrypts the `encUserKey` EncString (from the sync response profile) using the
    /// stretched master keys, and returns the 64-byte vault symmetric `CryptoKeys`.
    ///
    /// Per the Bitwarden Security Whitepaper §5: the encUserKey is a Type-2 EncString
    /// that contains the 64-byte user symmetric key (encKey || macKey).
    ///
    /// - Parameters:
    ///   - encUserKey:    The EncString from `SyncResponse.profile.key`.
    ///   - stretchedKeys: The stretched master key pair used to decrypt it.
    /// - Returns: The 64-byte vault `CryptoKeys`.
    func decryptSymmetricKey(encUserKey: String, stretchedKeys: CryptoKeys) async throws -> CryptoKeys

    /// Decrypts a list of raw ciphers using the current vault keys.
    ///
    /// Organisation ciphers (`organizationId != nil`) are silently skipped in v1.
    /// Per-cipher decryption failures are non-fatal: failed items are excluded and counted.
    ///
    /// - Parameter ciphers: Raw encrypted ciphers from the sync response.
    /// - Returns: Tuple of successfully decrypted `VaultItem`s, a failure count, and the key source
    ///   of every decrypted item (for `VaultKeyCache`).
    /// - Throws: `PrizmCryptoServiceError.vaultLocked` if the vault is not unlocked.
    func decryptList(ciphers: [RawCipher]) async throws -> (items: [VaultItem], failedCount: Int, keySources: [String: CipherKeySource])

    /// Decrypts folder names from the sync response.
    ///
    /// Per-folder decryption failures are non-fatal: failed folders are excluded and counted.
    /// - Parameter folders: Raw encrypted folders from the sync response.
    /// - Returns: Tuple of successfully decrypted `Folder`s and a failure count.
    /// - Throws: `PrizmCryptoServiceError.vaultLocked` if the vault is not unlocked.
    func decryptFolders(folders: [RawFolder]) async throws -> (folders: [Folder], failedCount: Int)

    /// Loads `keys` into memory, marking the vault as unlocked.
    func unlockWith(keys: CryptoKeys) async

    /// Zeroes and discards all in-memory key material, locking the vault.
    ///
    /// After this call, `isUnlocked` returns `false` and any attempt to decrypt
    /// vault items will throw `PrizmCryptoServiceError.vaultLocked`.
    func lockVault() async

    /// Returns the current vault symmetric key pair for callers that need to perform
    /// encryption (e.g. the reverse cipher mapper for PUT /ciphers/{id}).
    ///
    /// - Throws: `PrizmCryptoServiceError.vaultLocked` if the vault is locked.
    func currentKeys() async throws -> CryptoKeys

    // MARK: - Org key crypto (org-support)

    /// Decrypts the user's RSA private key from its EncString representation.
    ///
    /// The profile's `privateKey` EncString is a Type-2 (AES-256-CBC + HMAC-SHA256) EncString
    /// encrypted with the vault symmetric key. Decrypting it yields raw PKCS#8 DER bytes for
    /// the user's RSA-2048 private key.
    ///
    /// - Security goal: the decrypted private key bytes are used only within `unwrapOrgKey`
    ///   to decrypt org symmetric keys. The caller must zero the returned `Data` after use.
    ///   The bytes are NEVER logged (Constitution §III, §VII).
    ///
    /// - Parameters:
    ///   - encPrivateKey: EncString from `SyncResponse.profile.privateKey`.
    ///   - vaultKeys:     The vault symmetric `CryptoKeys` used to decrypt it.
    /// - Returns: Raw PKCS#8 DER bytes of the RSA private key.
    /// - Throws: `PrizmCryptoServiceError` on decryption failure.
    func decryptRSAPrivateKey(encPrivateKey: String, vaultKeys: CryptoKeys) async throws -> Data

    /// Unwraps an organization's symmetric key using the user's RSA private key.
    ///
    /// The org key EncString (Type-4) contains the org's 64-byte symmetric key encrypted
    /// with RSA-OAEP-SHA1 using the user's RSA-2048 public key.
    ///
    /// - Algorithm: `SecKeyCreateDecryptedData` with `kSecKeyAlgorithmRSAEncryptionOAEPSHA1`.
    ///   SHA-1 is used here because it is the Bitwarden protocol requirement (Security Whitepaper §4),
    ///   not a free choice. RSA-OAEP with SHA-1 remains secure for key transport when used as
    ///   specified; the weakness of standalone SHA-1 collision resistance does not apply here.
    ///   Reference: Bitwarden Security Whitepaper §4 — "Organization Key Wrapping".
    ///
    /// - PKCS#8 stripping: Bitwarden stores the RSA private key as a PKCS#8-wrapped DER blob.
    ///   `SecKeyCreateWithData` requires the raw RSA key material without the PKCS#8 header.
    ///   `stripPKCS8Header` reads the outer SEQUENCE, the version, the AlgorithmIdentifier (which
    ///   must be rsaEncryption) and returns the content of the OCTET STRING: the PKCS#1
    ///   RSAPrivateKey DER bytes (RFC 5208 §5).
    ///
    /// - What is NOT done: This function does not cache the RSA private key — callers must
    ///   pass the already-decrypted key bytes and zero them immediately after use.
    ///
    /// - Parameters:
    ///   - encOrgKey:     Type-4 EncString from `RawOrganization.key`.
    ///   - rsaPrivateKey: PKCS#8 DER bytes of the user's RSA private key (from `decryptRSAPrivateKey`).
    /// - Returns: The 64-byte `CryptoKeys` pair for the organization.
    /// - Throws: `PrizmCryptoServiceError` on RSA decryption failure.
    func unwrapOrgKey(encOrgKey: String, rsaPrivateKey: Data) async throws -> CryptoKeys

    // MARK: - Attachment crypto (vault-document-storage)
    //
    // Declared `nonisolated` so they can be called synchronously from any concurrency
    // context — they access no actor-isolated state and can therefore be tested via
    // `any PrizmCryptoService` without requiring `await`.

    /// Generates a cryptographically random 64-byte per-attachment key.
    ///
    /// See `AttachmentCrypto.swift` for the full specification.
    nonisolated func generateAttachmentKey() throws -> Data

    /// Encrypts file data using AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC).
    /// Binary layout: the official EncArrayBuffer `0x02 ‖ IV (16) ‖ HMAC-SHA256 (32) ‖ ciphertext`.
    nonisolated func encryptData(_ data: Data, attachmentKey: Data) throws -> Data

    /// Decrypts an attachment file in the official layout or in Prizm's old layout
    /// (`AttachmentBlobLayout`). Verifies HMAC before decrypting (Encrypt-then-MAC).
    nonisolated func decryptData(_ data: Data, attachmentKey: Data) throws -> Data

    /// Wraps the per-attachment key as a type-2 EncString using the cipher's `CryptoKeys`.
    nonisolated func encryptAttachmentKey(_ key: Data, cipherKey: CryptoKeys) throws -> String

    /// Unwraps a per-attachment key from its EncString representation.
    nonisolated func decryptAttachmentKey(_ encString: String, cipherKey: CryptoKeys) throws -> Data

    /// Encrypts a plaintext file name as a type-2 EncString for upload metadata.
    nonisolated func encryptFileName(_ name: String, cipherKey: CryptoKeys) throws -> String

    // MARK: - One-time-code HMAC (TOTP)

    /// Computes HMAC(`key`, `message`) with the given hash and returns the full MAC
    /// (20, 32 or 64 bytes).
    ///
    /// - Security goal: derive a time-based one-time code (RFC 6238) from a stored seed.
    ///   Stateless — it uses neither the vault keys nor any actor state, so it is `nonisolated`
    ///   and works without an unlocked vault; the caller already holds the decrypted seed.
    /// - Standards: HMAC per RFC 2104; hash choice per RFC 6238 §1.2.
    /// - SHA-1: it is the RFC 6238 default and what nearly every service issues. SHA-1's known
    ///   weakness is collision resistance, which HMAC does not rely on, so HMAC-SHA-1 remains
    ///   a sound MAC here. Rejecting it would make most real seeds unusable.
    nonisolated func hmac(_ algorithm: TOTPHashAlgorithm, key: Data, message: Data) -> Data
}

// MARK: - PrizmCryptoServiceImpl

/// Concrete implementation of `PrizmCryptoService`.
///
/// Key derivation algorithms:
/// - **PBKDF2-SHA256** (RFC 8018 §5.2, NIST SP 800-132): used when
///   `KdfParams.type == .pbkdf2`.  Implemented via CommonCrypto `CCKeyDerivationPBKDF`.
/// - **Argon2id** (RFC 9106): used when `KdfParams.type == .argon2id`.
///   Delegated to the vendored `Argon2Swift` library.
/// - **HKDF-Expand** (RFC 5869 §2.3, no Extract): used for key stretching in `stretchKey`.
///   One HMAC-SHA256 block from CryptoKit `HMAC<SHA256>`; equal to CryptoKit
///   `HKDF<SHA256>.expand` and the SDK vector (`KeyStretchKATTests`).
actor PrizmCryptoServiceImpl: PrizmCryptoService {

    #if DEBUG
    /// Test seam: the user-key scratch buffer of `decryptSymmetricKey` right after zeroing, and
    /// whether it was zeroed in place (not in a copy).
    private var scratchZeroedObserver: (@Sendable (Data, Bool) -> Void)?
    func setScratchZeroedObserver(_ observer: (@Sendable (Data, Bool) -> Void)?) {
        scratchZeroedObserver = observer
    }
    #endif

    private let logger = Logger(subsystem: "com.prizm", category: "PrizmCryptoService")

    // MARK: - State

    /// The decrypted vault symmetric key pair, non-nil only when unlocked.
    /// Stored as `var` so it can be zeroed on lock.
    private var keys: CryptoKeys?

    var isUnlocked: Bool { keys != nil }

    // MARK: - Lock / Unlock

    func unlockWith(keys: CryptoKeys) {
        // Keys of an earlier unlock that was not locked before are zeroed first, not just dropped.
        zeroStoredKeys()
        self.keys = keys
        logger.info("Vault unlocked")
    }

    func lockVault() {
        zeroStoredKeys()
        logger.info("Vault locked — key material zeroed")
    }

    private func zeroStoredKeys() {
        // Zero both key buffers in the actor's stored property before releasing.
        // `self.keys` is the primary reference — zeroing it reduces the window during
        // which key material exists in a heap dump (Constitution §III). Any Data copies
        // passed to in-flight decryption tasks retain their own CoW buffers until those
        // tasks complete; those copies cannot be zeroed here.
        // Data slices retain nonzero indices; capture them before mutating keys.
        if let encRange = keys?.encryptionKey.indices,
           let macRange = keys?.macKey.indices {
            keys!.encryptionKey.resetBytes(in: encRange)
            keys!.macKey.resetBytes(in: macRange)
        }
        keys = nil
    }

    func currentKeys() throws -> CryptoKeys {
        guard let vaultKeys = keys else {
            throw PrizmCryptoServiceError.vaultLocked
        }
        return vaultKeys
    }

    // MARK: - decryptList

    func decryptList(ciphers: [RawCipher]) async throws -> (items: [VaultItem], failedCount: Int, keySources: [String: CipherKeySource]) {
        guard let vaultKeys = keys else {
            throw PrizmCryptoServiceError.vaultLocked
        }
        logger.info("decryptList: starting with \(ciphers.count) ciphers")
        let mapper = CipherMapper()
        var items: [VaultItem] = []
        var keySources: [String: CipherKeySource] = [:]
        var failedCount = 0
        for (index, cipher) in ciphers.enumerated() {
            if cipher.organizationId != nil {
                if DebugConfig.isEnabled {
                    logger.debug("[debug] cipher[\(index, privacy: .public)] skipped — organizationId present")
                }
                continue
            }
            do {
                let (item, cipherKey) = try mapper.map(raw: cipher, keys: vaultKeys)
                items.append(item)
                // Every item gets a source, so an attachment never has to guess its key
                // (fix-org-attachment-key, D2).
                keySources[cipher.id] = .of(cipher, effectiveKey: cipherKey)
                if DebugConfig.isEnabled {
                    let rawAttachmentCount = cipher.attachments?.count ?? 0
                    let mappedAttachmentCount = item.attachments.count
                    logger.debug("[debug] cipher[\(index, privacy: .public)] OK — type=\(cipher.type, privacy: .public) id=\(cipher.id, privacy: .private) rawAttachments=\(rawAttachmentCount, privacy: .public) mappedAttachments=\(mappedAttachmentCount, privacy: .public)")
                }
            } catch {
                failedCount += 1
                logger.error("decryptList: Cipher decryption failed at index \(index, privacy: .public)")
                if DebugConfig.isEnabled {
                    logger.debug("[debug] cipher[\(index, privacy: .public)] FAILED — type=\(cipher.type, privacy: .public) error=\(ErrorLog.describe(error), privacy: .public)")
                }
            }
        }
        logger.info("decryptList: completed — \(items.count) succeeded, \(failedCount) failed")
        return (items: items, failedCount: failedCount, keySources: keySources)
    }

    // MARK: - decryptFolders

    func decryptFolders(folders rawFolders: [RawFolder]) async throws -> (folders: [Folder], failedCount: Int) {
        guard let vaultKeys = keys else {
            throw PrizmCryptoServiceError.vaultLocked
        }
        var folders: [Folder] = []
        var failedCount = 0
        for raw in rawFolders {
            do {
                let enc  = try EncString(string: raw.name)
                let data = try enc.decrypt(keys: vaultKeys)
                guard let name = String(data: data, encoding: .utf8) else {
                    failedCount += 1
                    continue
                }
                folders.append(Folder(id: raw.id, name: name))
            } catch {
                failedCount += 1
                logger.error("decryptFolders: folder decryption failed for id \(raw.id, privacy: .public)")
            }
        }
        return (folders: folders, failedCount: failedCount)
    }

    // MARK: - makeMasterKey

    /// Master key derivation as the Bitwarden SDK does it (`bitwarden-crypto/src/keys/kdf.rs`;
    /// openspec change `fix-kdf-derivation-and-validation`, design D1–D3).
    ///
    /// - Security goal: the same master key, and so the same server hash, as every official client
    ///   for the same password, salt and settings; and no derivation at all with settings a server
    ///   could use to obtain a cheap hash (`KdfValidator`, checked first, at login and at unlock).
    /// - Salt: trimmed and lowercased, as SDK `derive` does, so a typed space or capital letter
    ///   cannot change the key.
    /// - PBKDF2-SHA256 (RFC 8018 §5.2) over the salt's UTF-8 bytes, 32-byte output.
    /// - Argon2id (RFC 9106): see `argon2idDerive`.
    func makeMasterKey(password: Data, salt: String, kdf: KdfParams) async throws -> Data {
        switch KdfValidator.check(kdf) {
        case .tooWeak?:
            logger.error("KDF settings below the minimums; derivation refused")
            throw PrizmCryptoServiceError.insufficientKdfParameters
        case .invalid?:
            logger.error("KDF settings unusable; derivation refused")
            throw PrizmCryptoServiceError.invalidKdfParameters
        case nil:
            break
        }
        let saltData = Data(salt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)

        logger.debug("KDF: using \(String(describing: kdf.type), privacy: .public)")

        switch kdf.type {
        case .pbkdf2:
            return try pbkdf2SHA256(
                password: password,
                salt:     saltData,
                rounds:   UInt32(kdf.iterations),  // in range: KdfValidator
                keyLen:   32
            )
        case .argon2id:
            guard let memory      = kdf.memory,
                  let parallelism = kdf.parallelism else {
                throw PrizmCryptoServiceError.invalidKdfParameters  // unreachable: KdfValidator
            }
            return try argon2idDerive(
                password:    password,
                salt:        saltData,
                iterations:  kdf.iterations,
                memoryMiB:   memory,
                parallelism: parallelism
            )
        }
    }

    // MARK: - stretchKey

    func stretchKey(masterKey: Data) async throws -> CryptoKeys {
        // Bitwarden Key Stretching (Security Whitepaper §4):
        //   encKey = HKDF-Expand(PRK=masterKey, info="enc", len=32)
        //   macKey = HKDF-Expand(PRK=masterKey, info="mac", len=32)
        //
        // Bitwarden uses HKDF-Expand ONLY (RFC 5869 §2.3): it skips the Extract step and uses
        // the 32-byte masterKey directly as the PRK (SDK `keys/utils.rs` `stretch_key`, which
        // calls `Hkdf::<Sha256>::from_prk(..).expand`). Full HKDF (`HKDF.deriveKey`, Extract +
        // Expand) gives different output and must not be used. CryptoKit's Expand-only
        // `HKDF<SHA256>.expand` gives the same result as `hkdfExpand` below; the helper stays
        // because it is reviewed and tested against both (KeyStretchKATTests; fix-encstring-
        // validation, D6).
        let encKey = hkdfExpand(prk: masterKey, info: Data("enc".utf8), outputLength: 32)
        let macKey = hkdfExpand(prk: masterKey, info: Data("mac".utf8), outputLength: 32)
        return CryptoKeys(encryptionKey: encKey, macKey: macKey)
    }

    /// HKDF-Expand only (RFC 5869 §2.3) for a single output block (≤ 32 bytes).
    ///
    /// `T(1) = HMAC-SHA256(key=PRK, data=info || 0x01)`
    ///
    /// Bitwarden passes the masterKey directly as PRK, bypassing the Extract phase, as the SDK's
    /// `hkdf_expand` (`util.rs`) does.
    private func hkdfExpand(prk: Data, info: Data, outputLength: Int) -> Data {
        precondition(outputLength <= 32, "Single-block HKDF-Expand limited to 32 bytes (SHA-256 hash length)")
        let input = info + Data([0x01])   // T(0)=empty || info || counter=1
        let mac   = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: prk))
        return Data(mac).prefix(outputLength)
    }

    // MARK: - makeServerHash

    func makeServerHash(masterKey: Data, password: Data) async throws -> String {
        // serverHash = PBKDF2-SHA256(masterKey, password, 1 iteration, 32 bytes)
        // Per Bitwarden Security Whitepaper §4: "Local Password Hash"
        let hash = try pbkdf2SHA256(password: masterKey, salt: password, rounds: 1, keyLen: 32)
        return hash.base64EncodedString()
    }

    // MARK: - decryptSymmetricKey

    func decryptSymmetricKey(encUserKey: String, stretchedKeys: CryptoKeys) async throws -> CryptoKeys {
        if DebugConfig.isEnabled {
            logger.debug("[debug] decryptSymmetricKey: encUserKey type prefix=\(String(encUserKey.prefix(2)), privacy: .public) len=\(encUserKey.count, privacy: .public)")
        }
        let enc: EncString
        do {
            enc = try EncString(string: encUserKey)
        } catch {
            logger.error("Failed to parse encUserKey EncString: \(ErrorLog.describe(error), privacy: .public)")
            throw PrizmCryptoServiceError.invalidEncUserKey
        }
        // Defence in depth: `decrypt` refuses every type but 2 too; this check logs the type the
        // server sent (fix-encstring-validation, D1). A type-0 user key is a legacy account, which
        // official clients refuse ("legacyEncryptionUnsupported"); `account-scope-and-unsupported-features`
        // is to give it a named message here.
        guard enc.encType == .aes256Cbc_HmacSha256_B64 else {
            logger.error("encUserKey is EncString type \(enc.encType.rawValue, privacy: .public), not 2")
            throw PrizmCryptoServiceError.invalidEncUserKey
        }

        var keyData: Data
        do {
            keyData = try enc.decrypt(keys: stretchedKeys)
        } catch {
            logger.error("Failed to decrypt encUserKey: \(ErrorLog.describe(error), privacy: .public)")
            throw PrizmCryptoServiceError.invalidEncUserKey
        }
        // The returned keys get their own buffers (`subdata` copies), so this 64-byte scratch
        // buffer can be zeroed; slices would share it (harden-key-lifecycle-and-logging, D3).
        defer {
            #if DEBUG
            let before = keyData.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
            #endif
            keyData.resetBytes(in: keyData.indices)
            #if DEBUG
            let after = keyData.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
            scratchZeroedObserver?(keyData, before == after)
            #endif
        }

        guard keyData.count == 64 else {
            logger.error("Decrypted symmetric key has wrong length: \(keyData.count, privacy: .public) bytes (expected 64)")
            throw PrizmCryptoServiceError.invalidSymmetricKeyLength
        }

        let start = keyData.startIndex
        return CryptoKeys(
            encryptionKey: keyData.subdata(in: start..<(start + 32)),
            macKey:        keyData.subdata(in: (start + 32)..<(start + 64))
        )
    }

    // MARK: - Org key crypto (RSA-OAEP-SHA1)

    /// Decrypts the user's RSA private key from its EncString representation.
    ///
    /// - Security goal: the decrypted PKCS#8 DER bytes are returned to the caller who
    ///   must zero them immediately after passing to `unwrapOrgKey`. The bytes are NEVER
    ///   logged (Constitution §III — "no secrets in logs").
    ///
    /// - The `privateKey` field in the sync profile is a Type-2 EncString (AES-256-CBC +
    ///   HMAC-SHA256) encrypted with the vault symmetric key. Decrypting it yields the
    ///   PKCS#8 DER-encoded RSA-2048 private key.
    func decryptRSAPrivateKey(encPrivateKey: String, vaultKeys: CryptoKeys) throws -> Data {
        let enc: EncString
        do {
            enc = try EncString(string: encPrivateKey)
        } catch {
            logger.error("decryptRSAPrivateKey: failed to parse EncString: \(ErrorLog.describe(error), privacy: .public)")
            throw PrizmCryptoServiceError.invalidEncUserKey
        }
        do {
            return try enc.decrypt(keys: vaultKeys)
        } catch {
            logger.error("decryptRSAPrivateKey: AES-CBC decryption failed: \(ErrorLog.describe(error), privacy: .public)")
            throw PrizmCryptoServiceError.invalidEncUserKey
        }
    }

    /// Unwraps an organization's symmetric key using the user's RSA private key.
    ///
    /// - Algorithm: RSA-OAEP-SHA1 via `Security.framework`.
    ///   `kSecKeyAlgorithmRSAEncryptionOAEPSHA1` — SHA-1 is used here because it is the
    ///   Bitwarden protocol requirement (Security Whitepaper §4), not a free choice.
    ///   RSA-OAEP with SHA-1 is secure for key transport; the SHA-1 collision weakness
    ///   applies only to digital signatures, not OAEP key wrapping.
    ///   Reference: Bitwarden Security Whitepaper §4 — "Organization Key Wrapping".
    ///
    /// - PKCS#8 stripping: Bitwarden stores the RSA private key as a PKCS#8-wrapped blob.
    ///   `SecKeyCreateWithData` (kSecAttrKeyTypeRSA) requires the raw PKCS#1 RSAPrivateKey
    ///   DER bytes, not the PKCS#8 wrapper. The PKCS#8 outer structure is:
    ///     SEQUENCE {
    ///       INTEGER (version = 0)
    ///       SEQUENCE { OID rsaEncryption, NULL }  ← AlgorithmIdentifier
    ///       OCTET STRING { <PKCS#1 RSAPrivateKey> }
    ///     }
    ///   We skip the outer SEQUENCE + INTEGER + SEQUENCE (AlgorithmIdentifier) + OCTET STRING
    ///   header bytes to reach the raw PKCS#1 content.
    ///
    /// - Type-4 EncString only: `4.<base64 RSA ciphertext>`, one part, no IV or MAC (RSA-OAEP's
    ///   padding is the integrity check). Current clients write type 4 for organization keys
    ///   (SDK `enc_string/asymmetric.rs:184-198`).
    /// - Intentionally NOT done: types 3, 5 and 6 (OAEP-SHA256, and the variants with an HMAC part)
    ///   are refused with `unsupportedOrgKeyType` before any RSA work. No current writer of them was
    ///   found; unwrapping them can be added if such keys turn up (fix-encstring-validation, D4).
    func unwrapOrgKey(encOrgKey: String, rsaPrivateKey: Data) throws -> CryptoKeys {
        let rsaCiphertext = try parseOrgKeyEncString(encOrgKey)

        // Strip PKCS#8 wrapper to obtain raw PKCS#1 RSAPrivateKey DER bytes.
        let pkcs1Bytes = try stripPKCS8Header(from: rsaPrivateKey)

        // Import the RSA private key via Security.framework.
        // kSecAttrKeyTypeRSA + kSecAttrKeyClassPrivate + raw PKCS#1 DER.
        var importError: Unmanaged<CFError>?
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String:  kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]
        guard let secKey = SecKeyCreateWithData(pkcs1Bytes as CFData, keyAttributes as CFDictionary, &importError) else {
            let err = importError?.takeRetainedValue()
            logger.error("unwrapOrgKey: SecKeyCreateWithData failed: \(err.debugDescription, privacy: .public)")
            throw PrizmCryptoServiceError.malformedPrivateKey
        }

        // Decrypt org key bytes using RSA-OAEP-SHA1.
        // SHA-1 is mandated by the Bitwarden protocol — not a free choice.
        var decryptError: Unmanaged<CFError>?
        guard let orgKeyData = SecKeyCreateDecryptedData(
            secKey,
            .rsaEncryptionOAEPSHA1,
            rsaCiphertext as CFData,
            &decryptError
        ) as Data? else {
            let err = decryptError?.takeRetainedValue()
            logger.error("unwrapOrgKey: RSA-OAEP-SHA1 decryption failed: \(err.debugDescription, privacy: .public)")
            throw PrizmCryptoServiceError.orgKeyUnwrapFailed
        }

        guard orgKeyData.count == 64 else {
            logger.error("unwrapOrgKey: decrypted org key has wrong length \(orgKeyData.count, privacy: .public) (expected 64)")
            throw PrizmCryptoServiceError.invalidSymmetricKeyLength
        }

        // Own buffers for the two halves: slices would share one buffer, and zeroing the first
        // half on lock would then zero a copy-on-write copy (harden-key-lifecycle-and-logging).
        let start = orgKeyData.startIndex
        return CryptoKeys(
            encryptionKey: orgKeyData.subdata(in: start..<(start + 32)),
            macKey:        orgKeyData.subdata(in: (start + 32)..<(start + 64))
        )
    }

    /// Parses an organization key EncString and returns the RSA ciphertext of a type-4 key.
    ///
    /// Part counts as in the official enum (`encryption-type.enum.ts:41-49`): 3 and 4 have one part,
    /// 5 and 6 two. Only a one-part type 4 with valid Base64 is accepted.
    private func parseOrgKeyEncString(_ encString: String) throws -> Data {
        guard let (number, body) = EncString.splitHeader(encString),
              let type = AsymmetricEncType(rawValue: number) else {
            logger.error("Org key is not an RSA EncString")
            throw PrizmCryptoServiceError.malformedOrgKey
        }
        guard type == .rsa2048OaepSha1_B64 else {
            logger.error("Org key has unsupported EncString type \(number, privacy: .public)")
            throw PrizmCryptoServiceError.unsupportedOrgKeyType(number)
        }
        let parts = body.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 1, let ciphertext = Data(base64Encoded: String(parts[0])), !ciphertext.isEmpty else {
            logger.error("Org key of type 4 is malformed")
            throw PrizmCryptoServiceError.malformedOrgKey
        }
        return ciphertext
    }

    /// Strips the PKCS#8 wrapper (RFC 5208 §5) from a DER-encoded RSA private key and returns the
    /// PKCS#1 `RSAPrivateKey` inside, which `SecKeyCreateWithData` needs; no Apple API imports
    /// PKCS#8 RSA keys directly.
    ///
    /// `SEQUENCE { INTEGER version, SEQUENCE { OID rsaEncryption, NULL }, OCTET STRING { PKCS#1 } }`
    ///
    /// - Security goal: the bytes come from the server (decrypted with the vault key), so they are
    ///   untrusted input. Every length is checked against the bytes that remain, long-form lengths
    ///   are at most 4 bytes, the indefinite form is refused, each element must end inside the
    ///   outer SEQUENCE, and the algorithm must be rsaEncryption (1.2.840.113549.1.1.1). Any
    ///   violation throws `malformedPrivateKey`; nothing traps (fix-encstring-validation, D5).
    /// - Intentionally NOT done: a general ASN.1 parser or a library for it; this reads framing
    ///   only, it is not a cryptographic algorithm (§VI).
    ///
    /// Returns a slice of `pkcs8`, not a copy: it shares the caller's buffer, so zeroing the
    /// decrypted private key also zeroes the PKCS#1 bytes, and no other copy of the key is made
    /// (Constitution §III; code review 2026-10-30).
    private func stripPKCS8Header(from pkcs8: Data) throws -> Data {
        let range = try pkcs8.withUnsafeBytes { raw -> Range<Int> in
            try Self.pkcs1Range(in: raw.bindMemory(to: UInt8.self))
        }
        return pkcs8[(pkcs8.startIndex + range.lowerBound)..<(pkcs8.startIndex + range.upperBound)]
    }

    /// The offsets of the PKCS#1 key inside a PKCS#8 DER buffer, read in place.
    private static func pkcs1Range(in bytes: UnsafeBufferPointer<UInt8>) throws -> Range<Int> {
        var index = 0

        /// Reads a tag and its length; returns the content range, which lies inside `limit`.
        func readElement(tag: UInt8, limit: Int) throws -> Range<Int> {
            guard index < limit, bytes[index] == tag else { throw PrizmCryptoServiceError.malformedPrivateKey }
            index += 1
            guard index < limit else { throw PrizmCryptoServiceError.malformedPrivateKey }
            let first = bytes[index]
            index += 1
            var length = Int(first)
            if first & 0x80 != 0 {
                let count = Int(first & 0x7F)
                guard (1...4).contains(count), count <= limit - index else {
                    throw PrizmCryptoServiceError.malformedPrivateKey
                }
                length = bytes[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard length <= limit - index else { throw PrizmCryptoServiceError.malformedPrivateKey }
            return index..<(index + length)
        }

        let outer = try readElement(tag: 0x30, limit: bytes.count)
        let version = try readElement(tag: 0x02, limit: outer.upperBound)
        index = version.upperBound
        let algorithm = try readElement(tag: 0x30, limit: outer.upperBound)
        let oid = try readElement(tag: 0x06, limit: algorithm.upperBound)
        guard Array(bytes[oid]) == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01] else {
            throw PrizmCryptoServiceError.malformedPrivateKey
        }
        index = algorithm.upperBound
        let pkcs1 = try readElement(tag: 0x04, limit: outer.upperBound)
        guard !pkcs1.isEmpty else { throw PrizmCryptoServiceError.malformedPrivateKey }
        return pkcs1
    }

    // MARK: - PBKDF2-SHA256 (CommonCrypto)

    /// Derives a key using PBKDF2-SHA256 via CommonCrypto `CCKeyDerivationPBKDF`.
    ///
    /// CommonCrypto implements PBKDF2 as specified in RFC 8018 §5.2 and is validated
    /// under FIPS 140-2 as part of macOS's Common Crypto library.  This function is
    /// used for both the master key derivation (where `salt = email`) and the server
    /// hash (where `salt = password`, `rounds = 1`).
    ///
    /// - Parameters:
    ///   - password: Password bytes.
    ///   - salt:     Salt bytes.
    ///   - rounds:   Iteration count (≥ 1).
    ///   - keyLen:   Desired output key length in bytes (typically 32).
    /// - Throws: `PrizmCryptoServiceError.kdfFailed` if CommonCrypto returns a non-zero status.
    private func pbkdf2SHA256(password: Data, salt: Data, rounds: UInt32, keyLen: Int) throws -> Data {
        var derivedKey = Data(count: keyLen)
        let status = derivedKey.withUnsafeMutableBytes { dkPtr in
            password.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        dkPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLen
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw PrizmCryptoServiceError.kdfFailed
        }
        return derivedKey
    }

    // MARK: - Argon2id (Argon2Swift)

    /// Derives a key using Argon2id via the vendored `Argon2Swift` library.
    ///
    /// Argon2id (RFC 9106), version 0x13, 32-byte output, as the Bitwarden SDK
    /// (`bitwarden-crypto/src/keys/kdf.rs`). Two Bitwarden-specific inputs, both needed for the
    /// server to accept the resulting hash (fix-kdf-derivation-and-validation, D1):
    /// - the Argon2 salt is the SHA-256 of the salt bytes, not the bytes themselves. Bitwarden
    ///   hashes it (SDK `kdf.rs`), so the Argon2 salt is always 32 bytes, whatever the salt string;
    /// - the server sends memory in MiB; Argon2 takes KiB, so it is multiplied by 1024.
    ///
    /// Note: The raw hash bytes are extracted (not the Argon2 encoded string) because
    /// only the 32-byte derived key material is needed, not the self-describing hash.
    ///
    /// - Parameters:
    ///   - password:    Password bytes.
    ///   - salt:        Salt bytes (the normalized salt string); hashed here.
    ///   - iterations:  Time cost (number of passes).
    ///   - memoryMiB:   Memory cost in MiB, as the server sends it (checked by `KdfValidator`).
    ///   - parallelism: Degree of parallelism (number of threads).
    /// - Throws: `PrizmCryptoServiceError.kdfFailed` if Argon2Swift returns an error.
    private func argon2idDerive(
        password:    Data,
        salt:        Data,
        iterations:  Int,
        memoryMiB:   Int,
        parallelism: Int
    ) throws -> Data {
        // Argon2Swift is imported from the local vendored package.
        // The `Argon2Swift.hash(password:salt:iterations:memory:parallelism:type:)`
        // API returns a `Argon2SwiftResult`; we take `.hashData` (raw bytes).
        // `hashPasswordBytes` maps directly to the reference argon2_hash C function.
        // `.id` selects Argon2id (the hybrid variant recommended by RFC 9106 §4).
        // `length: 32` produces a 256-bit derived key suitable for AES-256 key material.
        let result = try Argon2Swift.hashPasswordBytes(
            password:    password,
            salt:        Salt(bytes: Data(SHA256.hash(data: salt))),
            iterations:  iterations,
            memory:      memoryMiB * 1024,
            parallelism: parallelism,
            length:      32,
            type:        .id
        )
        // The result's arrays hold the derived master key; zero them once the caller's copy is made.
        defer { result.zero() }
        return result.hashData()
    }
}
