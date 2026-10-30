import Foundation

// MARK: - VaultKeyService

/// Provides the effective cipher key for a given vault item, used by attachment
/// upload and download use cases.
///
/// The returned 64-byte `Data` is `encryptionKey ‖ macKey` — the same layout that
/// `CryptoKeys` stores as two separate 32-byte fields. Passing raw `Data` rather than
/// `CryptoKeys` keeps the Domain layer free of Data-layer types (Constitution §II).
///
/// Implemented by `VaultKeyServiceImpl` in the Data layer. Foundation-only — no crypto
/// imports belong in the Domain layer.
protocol VaultKeyService: Sendable {

    /// Returns the 64-byte effective cipher key for the vault item identified by `cipherId`:
    /// the item's own key if it has one, otherwise the organization key for an organization item,
    /// otherwise the personal vault key (fix-org-attachment-key, D1). Never a different key.
    ///
    /// - Parameter cipherId: The ID of the vault item.
    /// - Returns: 64-byte `Data` (encryptionKey ‖ macKey).
    /// - Throws: `VaultError.cipherKeyUnavailable` for an item the last sync or create did not
    ///   record, `VaultError.organizationKeyUnavailable` when the item's organization key is
    ///   missing, `VaultError.vaultLocked` when a personal item's key is needed while locked.
    func cipherKey(for cipherId: String) async throws -> Data

    /// Returns the 64-byte personal vault key. Only for attachments flagged
    /// `wrappedWithPersonalKey`, whose key was wrapped with it by mistake (design D3).
    ///
    /// - Throws: `VaultError.vaultLocked` when the vault is locked.
    func personalKey() async throws -> Data
}
