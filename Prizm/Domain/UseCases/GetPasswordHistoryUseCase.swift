import Foundation

/// Decrypts the password history of one item on demand, for the history sheet only
/// (openspec change `password-history`, design D1). Nothing decrypts it at sync.
///
/// Implemented by `GetPasswordHistoryUseCaseImpl` in the Data layer.
protocol GetPasswordHistoryUseCase: AnyObject {
    /// The entries in stored order; the caller sorts them for display.
    ///
    /// - Throws: `VaultError.vaultLocked` when the vault is locked or locks during the load,
    ///   `VaultError.itemRecordUnavailable` without a stored record, `VaultError.itemKeyUnavailable`
    ///   or `VaultError.organizationKeyUnavailable` when the item's key cannot be derived.
    func execute(itemId: String) async throws -> [PasswordHistoryEntry]
}
