import Foundation

/// Orchestrates the full account login flow:
/// validateServerURL → setServerEnvironment → loginWithPassword → (optional) loginWithTOTP → sync.
protocol LoginUseCase {
    func execute(
        serverURL: String,
        email: String,
        masterPassword: Data,
        flow: FlowToken
    ) async throws -> LoginResult

    /// - Parameter flow: the token of the sign-in this two-factor step belongs to; the sync after it
    ///   is fenced by it (lock-state-machine, design D8).
    func completeTOTP(code: String, rememberDevice: Bool, flow: FlowToken) async throws -> Account

    /// Cancels a pending TOTP challenge and clears in-memory key material held from
    /// the initial password-login step (see `AuthRepository.cancelTwoFactor`).
    func cancelTOTP()
}
