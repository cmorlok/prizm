import Foundation

final class SetFavoriteUseCaseImpl: SetFavoriteUseCase {
    private let repository: any VaultRepository
    init(repository: any VaultRepository) { self.repository = repository }

    func execute(itemId: String, isFavorite: Bool) async throws -> VaultItem {
        try await repository.setFavorite(itemId: itemId, isFavorite: isFavorite)
    }
}
