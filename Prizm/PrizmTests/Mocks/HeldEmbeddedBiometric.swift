import Foundation
import LocalAuthentication
@testable import Prizm

/// Embedded Touch ID that accepts the finger at once, then holds the unlock (key load, token
/// refresh) until the test opens `release`, so a lock can land in that window.
final class HeldEmbeddedBiometric: EmbeddedBiometricUnlock {
    let release = AsyncGate()
    private(set) var touched = false
    /// Thrown after `release`, as a failure after the touch (bad key item, network).
    var error: Error?
    private let account: Account

    init(account: Account) { self.account = account }

    func unlockWithBiometrics(context: LAContext, flow: FlowToken, onAuthenticated: () -> Void) async throws -> Account {
        onAuthenticated()
        touched = true
        await release.wait()
        if let error { throw error }
        return account
    }
}
