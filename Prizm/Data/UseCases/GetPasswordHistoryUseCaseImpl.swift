import Foundation

/// Delegates to `VaultRepository.passwordHistory(itemId:)`, which holds the stored records and
/// the keys.
final class GetPasswordHistoryUseCaseImpl: GetPasswordHistoryUseCase {

    private let repository: any VaultRepository

    init(repository: any VaultRepository) {
        self.repository = repository
    }

    func execute(itemId: String) async throws -> [PasswordHistoryEntry] {
        try await repository.passwordHistory(itemId: itemId)
    }
}
