import Foundation
import Synchronization

// MARK: - SessionGateImpl

/// `SessionGate` over a `Mutex`, so that every call is synchronous from any actor (design D1 of
/// `lock-state-machine`; the same pattern as `RawCipherStore`'s generation).
///
/// Holds no secret: a token is an object identity, compared with `===`.
nonisolated final class SessionGateImpl: SessionGate {

    private struct State {
        var token = FlowToken()
        var isOpen = true
    }

    private let state = Mutex(State())

    init() {}

    func begin() -> FlowToken {
        state.withLock { $0.isOpen ? $0.token : FlowToken() }
    }

    func isCurrent(_ token: FlowToken) -> Bool {
        state.withLock { $0.isOpen && $0.token == token }
    }

    func end() {
        state.withLock {
            $0.token = FlowToken()
            $0.isOpen = false
        }
    }

    func open() {
        state.withLock {
            guard !$0.isOpen else { return }
            // A fresh epoch, so a token handed out before `end()` stays stale even if a caller
            // compared it while closed.
            $0.token = FlowToken()
            $0.isOpen = true
        }
    }

    var isOpen: Bool {
        state.withLock { $0.isOpen }
    }
}
