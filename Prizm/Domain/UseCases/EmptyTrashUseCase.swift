import Foundation

/// Permanently deletes the items in Trash (openspec change fix-empty-trash).
///
/// Two steps, so the user confirms a count taken from fresh data: `prepare()` syncs and returns the
/// ids in Trash; after the user confirms, `execute(ids:)` deletes exactly those ids, syncs again and
/// reports what is still in Trash.
protocol EmptyTrashUseCase {
    func prepare() async throws -> [String]
    func execute(ids: [String]) async throws -> EmptyTrashResult
}

/// The outcome of Empty Trash, from the trash after the follow-up sync.
nonisolated struct EmptyTrashResult: Equatable {
    /// Why items were left, as far as Prizm can tell.
    enum Failure: Equatable {
        /// The server refused (for example, an org item the user may not delete).
        case refused
        /// The server could not be reached.
        case connection
    }

    let requested: Int
    /// Items the server confirmed as deleted.
    let deleted: Int
    /// Requested items still in Trash after the follow-up sync.
    let remaining: Int
    /// Set when a delete request failed.
    let failure: Failure?
    /// Whether the follow-up sync succeeded; if not, `remaining` comes from the cache.
    let synced: Bool
}

nonisolated enum EmptyTrashError: Error, LocalizedError {
    /// The sync before confirming failed; nothing was deleted.
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .refreshFailed: return "Couldn't refresh the trash. Try again."
        }
    }
}
