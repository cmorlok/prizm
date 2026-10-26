import Foundation
@testable import Prizm

/// Test double for `SyncUseCase`.
final class MockSyncUseCase: SyncUseCase {

    private(set) var executeCalled: Bool = false
    var stubbedResult: SyncResult = SyncResult(syncedAt: Date(), totalCiphers: 0, failedDecryptionCount: 0)
    var executeError: Error?
    private(set) var executeCount = 0
    /// Runs on each call before it returns, to change the vault as a real sync would.
    var onExecute: (() async -> Void)?
    /// Reported through the progress callback after `onExecute`, like a sync's last step.
    var progressMessage: String?

    func execute(progress: @Sendable @escaping (String) -> Void) async throws -> SyncResult {
        executeCalled = true
        executeCount += 1
        if let err = executeError { throw err }
        await onExecute?()
        if let progressMessage { progress(progressMessage) }
        return stubbedResult
    }
}
