import Foundation

/// Fetches the encrypted vault from the server and populates the in-memory store.
/// Called after login and after every relaunch + unlock.
protocol SyncUseCase {
    func execute(progress: @Sendable @escaping (String) -> Void) async throws -> SyncResult
    /// The sync that ends the sign-in or unlock `flow`, fenced by its token (lock-state-machine, D8).
    func execute(flow: FlowToken, progress: @Sendable @escaping (String) -> Void) async throws -> SyncResult
}
