import Foundation
@testable import Prizm

/// Test double for `PrizmCryptoService`.
actor MockPrizmCryptoService: PrizmCryptoService {

    // MARK: - State
    // nonisolated(unsafe) allows tests to read/write without await — safe in single-threaded tests.

    nonisolated(unsafe) var _isUnlocked: Bool = false
    nonisolated var isUnlocked: Bool { _isUnlocked }

    // MARK: - Stubs

    nonisolated(unsafe) var stubbedMasterKey:    Data   = Data(count: 32)
    nonisolated(unsafe) var stubbedStretchedKeys = CryptoKeys(
        encryptionKey: Data(count: 32),
        macKey:        Data(count: 32)
    )
    nonisolated(unsafe) var stubbedServerHash:   String = "stubServerHash=="
    nonisolated(unsafe) var stubbedVaultKeys    = CryptoKeys(
        encryptionKey: Data(count: 32),
        macKey:        Data(count: 32)
    )
    nonisolated(unsafe) var stubbedDecryptList:  [VaultItem] = []
    nonisolated(unsafe) var stubbedFailedCount:  Int = 0
    nonisolated(unsafe) var stubbedFolders:      [Folder] = []

    // MARK: - PrizmCryptoService

    // Fresh buffers on every call, as the real service returns: a shared buffer would make every
    // caller's in-place zeroing a copy-on-write copy instead (harden-key-lifecycle-and-logging).
    func makeMasterKey(password: Data, email: String, kdf: KdfParams) async throws -> Data {
        Data(Array(stubbedMasterKey))
    }

    func stretchKey(masterKey: Data) async throws -> CryptoKeys {
        CryptoKeys(encryptionKey: Data(Array(stubbedStretchedKeys.encryptionKey)),
                   macKey: Data(Array(stubbedStretchedKeys.macKey)))
    }

    func makeServerHash(masterKey: Data, password: Data) async throws -> String {
        stubbedServerHash
    }

    nonisolated(unsafe) var decryptSymmetricKeyError: Error?

    /// Runs while the user key is "being decrypted", to hold a login or unlock in its key derivation.
    nonisolated(unsafe) var whileDecryptingUserKey: (@Sendable () async -> Void)?

    func decryptSymmetricKey(encUserKey: String, stretchedKeys: CryptoKeys) async throws -> CryptoKeys {
        await whileDecryptingUserKey?()
        if let decryptSymmetricKeyError { throw decryptSymmetricKeyError }
        // Fresh buffers, as the real service returns, so callers can zero them in place.
        return CryptoKeys(encryptionKey: Data(Array(stubbedVaultKeys.encryptionKey)),
                          macKey: Data(Array(stubbedVaultKeys.macKey)))
    }

    func decryptList(ciphers: [RawCipher]) async throws -> (items: [VaultItem], failedCount: Int, cipherKeys: [String: Data]) {
        (items: stubbedDecryptList, failedCount: stubbedFailedCount, cipherKeys: [:])
    }

    func decryptFolders(folders: [RawFolder]) async throws -> (folders: [Folder], failedCount: Int) {
        (folders: stubbedFolders, failedCount: 0)
    }

    /// Runs while keys are "being loaded", to let a test lock in exactly that moment.
    nonisolated(unsafe) var whileUnlockingWith: (@MainActor () async -> Void)?

    func unlockWith(keys: CryptoKeys) async {
        _isUnlocked = true
        await whileUnlockingWith?()
    }

    func lockVault() async {
        _isUnlocked = false
    }

    /// Runs inside `currentKeys()`, the first await of a save after its own token check, so a test can
    /// lock the vault exactly there (a synchronous hook: `RawCipherStore.invalidate()` is enough).
    nonisolated(unsafe) var whileReadingKeys: (@Sendable () -> Void)?

    func currentKeys() throws -> CryptoKeys {
        whileReadingKeys?()
        guard _isUnlocked else { throw PrizmCryptoServiceError.vaultLocked }
        return stubbedVaultKeys
    }

    // MARK: - Org key crypto stubs

    nonisolated(unsafe) var stubbedRSAPrivateKey: Data = Data(count: 32)
    nonisolated(unsafe) var stubbedOrgKeys: [String: CryptoKeys] = [:]

    nonisolated(unsafe) var decryptRSAPrivateKeyError: Error?
    /// Blocks each org key unwrap this long, to hold a sync in the unwrap phase.
    nonisolated(unsafe) var unwrapOrgKeyDelay: TimeInterval = 0

    func decryptRSAPrivateKey(encPrivateKey: String, vaultKeys: CryptoKeys) throws -> Data {
        if let decryptRSAPrivateKeyError { throw decryptRSAPrivateKeyError }
        return stubbedRSAPrivateKey
    }

    /// Returns `stubbedOrgKeys[encOrgKey]`, or a deterministic zero key for any other value.
    /// Encrypted org keys whose unwrap fails, as for a corrupt or foreign key.
    nonisolated(unsafe) var failingOrgKeys: Set<String> = []

    func unwrapOrgKey(encOrgKey: String, rsaPrivateKey: Data) throws -> CryptoKeys {
        if unwrapOrgKeyDelay > 0 { Thread.sleep(forTimeInterval: unwrapOrgKeyDelay) }
        if failingOrgKeys.contains(encOrgKey) { throw PrizmCryptoServiceError.invalidSymmetricKeyLength }
        return stubbedOrgKeys[encOrgKey] ?? CryptoKeys(encryptionKey: Data(count: 32), macKey: Data(count: 32))
    }

    // MARK: - Attachment crypto stubs

    nonisolated(unsafe) var stubbedAttachmentKey: Data = Data(count: 32)
    nonisolated(unsafe) var stubbedEncryptedData: Data = Data()
    nonisolated(unsafe) var stubbedDecryptedData: Data = Data()
    nonisolated(unsafe) var stubbedEncAttachmentKey: String = "2.stubEncKey|stub|stub"
    nonisolated(unsafe) var stubbedDecAttachmentKey: Data = Data(count: 32)
    nonisolated(unsafe) var stubbedEncFileName: String = "2.stubName|stub|stub"

    nonisolated func generateAttachmentKey() throws -> Data { stubbedAttachmentKey }
    nonisolated func encryptData(_ data: Data, attachmentKey: Data) throws -> Data { stubbedEncryptedData }
    nonisolated func decryptData(_ data: Data, attachmentKey: Data) throws -> Data { stubbedDecryptedData }
    nonisolated func encryptAttachmentKey(_ key: Data, cipherKey: CryptoKeys) throws -> String { stubbedEncAttachmentKey }
    nonisolated func decryptAttachmentKey(_ encString: String, cipherKey: CryptoKeys) throws -> Data { stubbedDecAttachmentKey }
    nonisolated func encryptFileName(_ name: String, cipherKey: CryptoKeys) throws -> String { stubbedEncFileName }

    // MARK: - HMAC (TOTP) stub

    nonisolated(unsafe) var stubbedHMAC: Data = Data(repeating: 0, count: 20)
    nonisolated(unsafe) var lastHMACAlgorithm: TOTPHashAlgorithm?
    nonisolated(unsafe) var lastHMACKey: Data?
    nonisolated(unsafe) var lastHMACMessage: Data?

    nonisolated func hmac(_ algorithm: TOTPHashAlgorithm, key: Data, message: Data) -> Data {
        lastHMACAlgorithm = algorithm
        lastHMACKey = key
        lastHMACMessage = message
        return stubbedHMAC
    }

}
