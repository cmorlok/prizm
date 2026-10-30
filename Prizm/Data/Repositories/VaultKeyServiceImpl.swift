import Foundation
import os.log

// MARK: - VaultKeyServiceImpl

/// Concrete implementation of `VaultKeyService`.
///
/// Returns the effective 64-byte cipher key (encryptionKey ‖ macKey) for a vault item from the
/// key source the last sync or create recorded in `VaultKeyCache` (fix-org-attachment-key, D1):
///
/// 1. `.itemKey(k)` → `k`.
/// 2. `.organization(id)` → the key of that organization in `OrgKeyCache`, read now, so a key
///    replaced by the latest sync is used; missing → `VaultError.organizationKeyUnavailable`.
/// 3. `.personal` → the vault key from `crypto.currentKeys()` (locked → `VaultError.vaultLocked`).
/// 4. No entry → `VaultError.cipherKeyUnavailable`.
///
/// - Security goal: attachment keys and file names are wrapped with the key official clients use
///   for the item, so other organization members can open them, and key material never reaches
///   the Presentation layer (Constitution §II/§III).
/// - Algorithm: AES-256-CBC key (32 bytes) ‖ HMAC-SHA256 key (32 bytes) per Bitwarden Security
///   Whitepaper §4; key selection per SDK `bitwarden-vault/src/cipher/cipher.rs`
///   (`decrypt_cipher_key`, `key_identifier`, `make_attachment_material`).
/// - Deviations: none.
/// - What is NOT done: no fallback to the vault key for an organization item or an unknown item.
///   Before this change a cache miss returned the vault key, which wrapped org attachments with
///   the wrong key. No key material is persisted beyond the vault lock lifecycle.
final class VaultKeyServiceImpl: VaultKeyService {

    private let cache:       VaultKeyCache
    private let orgKeyCache: OrgKeyCache
    private let crypto:      any PrizmCryptoService

    private let logger = Logger(subsystem: "com.prizm", category: "attachments")

    init(cache: VaultKeyCache, orgKeyCache: OrgKeyCache, crypto: any PrizmCryptoService) {
        self.cache       = cache
        self.orgKeyCache = orgKeyCache
        self.crypto      = crypto
    }

    func cipherKey(for cipherId: String) async throws -> Data {
        switch await cache.source(for: cipherId) {
        case .itemKey(let key):
            return key
        case .organization(let orgId):
            guard let orgKeys = await orgKeyCache.snapshot()[orgId] else {
                logger.error("VaultKeyServiceImpl: no key for org \(orgId.prefix(8), privacy: .public)… of cipher \(cipherId, privacy: .public)")
                throw VaultError.organizationKeyUnavailable
            }
            return orgKeys.toData()
        case .personal:
            return try await personalKey()
        case nil:
            logger.error("VaultKeyServiceImpl: no key source for cipher \(cipherId, privacy: .public)")
            throw VaultError.cipherKeyUnavailable
        }
    }

    func personalKey() async throws -> Data {
        do {
            return try await crypto.currentKeys().toData()
        } catch PrizmCryptoServiceError.vaultLocked {
            logger.error("VaultKeyServiceImpl: vault is locked — cannot resolve cipher key")
            throw VaultError.vaultLocked
        }
    }
}
