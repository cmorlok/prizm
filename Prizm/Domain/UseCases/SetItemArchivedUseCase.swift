import Foundation

/// Archives or unarchives one item (openspec change `archived-items`, design D3). Offered for every
/// item, whatever the account's premium status: no server enforces one (design D4).
///
/// Implemented by `SetItemArchivedUseCaseImpl` in the Data layer.
protocol SetItemArchivedUseCase: AnyObject {
    /// - Throws: `VaultError.archiveUnsupported` on a server without archive, or the server's
    ///   refusal (`LocalizedError` with its message).
    func execute(id: String, archived: Bool) async throws
}
