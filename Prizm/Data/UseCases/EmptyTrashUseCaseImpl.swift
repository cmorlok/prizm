import Foundation
import os.log

final class EmptyTrashUseCaseImpl: EmptyTrashUseCase {
    private let repository: any VaultRepository
    private let sync: any SyncUseCase
    private let logger = Logger(subsystem: "com.prizm", category: "EmptyTrash")

    init(repository: any VaultRepository, sync: any SyncUseCase) {
        self.repository = repository
        self.sync = sync
    }

    /// Syncs, then returns the ids in Trash. Neither server checks that the ids it is asked to
    /// delete are trashed, so a stale list could delete an item restored on another device
    /// (fix-empty-trash, D2).
    func prepare() async throws -> [String] {
        do {
            _ = try await sync.execute(progress: { _ in })
        } catch {
            logger.error("Empty Trash: refresh failed (\(Self.describe(error), privacy: .public))")
            throw EmptyTrashError.refreshFailed
        }
        return try await repository.items(for: .trash).map(\.id)
    }

    /// Deletes `ids`, then syncs whatever happened, so the result matches the server: the official
    /// server skips items the user may not delete, Vaultwarden stops at the first one (D4).
    func execute(ids: [String]) async throws -> EmptyTrashResult {
        var deleted = 0
        var failure: EmptyTrashResult.Failure?
        do {
            deleted = try await repository.permanentDeleteItems(ids: ids)
        } catch let error as PermanentDeleteError {
            deleted = error.deleted
            failure = error.underlying is URLError ? .connection : .refused
            logger.error("Empty Trash: delete failed (\(Self.describe(error.underlying), privacy: .public))")
        } catch {
            failure = error is URLError ? .connection : .refused
            logger.error("Empty Trash: delete failed (\(Self.describe(error), privacy: .public))")
        }
        var synced = true
        do {
            _ = try await sync.execute(progress: { _ in })
        } catch {
            // The cache already reflects every chunk that succeeded; report from it.
            synced = false
            logger.error("Empty Trash: follow-up sync failed (\(Self.describe(error), privacy: .public))")
        }
        let remaining = try await repository.items(for: .trash).filter { ids.contains($0.id) }.count
        // After a successful sync, the server's own state says what is gone. The delete calls'
        // count can be wrong both ways: the official server answers 200 for items it skips, and
        // Vaultwarden may have deleted part of a chunk it then reports as failed.
        let confirmed = synced ? ids.count - remaining : deleted
        return EmptyTrashResult(requested: ids.count, deleted: confirmed, remaining: remaining,
                                failure: failure, synced: synced)
    }

    /// The HTTP status or error type only: an HTTP error's description carries the response body.
    private static func describe(_ error: Error) -> String {
        if case APIError.httpError(let status, _) = error { return "HTTP \(status)" }
        return String(describing: type(of: error))
    }
}
