import Foundation

/// Marks an item as favorite or removes the mark, and returns the updated item.
protocol SetFavoriteUseCase {
    func execute(itemId: String, isFavorite: Bool) async throws -> VaultItem
}
