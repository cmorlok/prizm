import XCTest
@testable import Prizm

/// A lock or sign-out closes the session gate as its first step and its teardown opens it again as
/// the last one, so nothing that starts in between counts (lock-state-machine, design D1).
@MainActor
final class RootViewModelSessionGateTests: XCTestCase {

    private var mockAuth: MockAuthRepository!
    private var deps: MockRootDependencies!
    private var sut: RootViewModel!

    private let account = Account(
        userId: "user-001", email: "alice@example.com", name: nil,
        serverEnvironment: ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil)
    )

    override func setUp() async throws {
        try await super.setUp()
        mockAuth = MockAuthRepository()
        mockAuth.stubbedStoredAccount = account
        deps = MockRootDependencies(auth: mockAuth, vault: MockVaultRepository(), defaults: makePrivateDefaults())
        sut = RootViewModel(container: deps)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testLockVault_closesTheGateBeforeItsFirstAwait() {
        sut.screen = .vault
        let before = deps.gate.begin()

        sut.lockVault()

        XCTAssertFalse(deps.gate.isOpen, "closed synchronously, before the teardown's first await")
        XCTAssertFalse(deps.gate.isCurrent(before))
    }

    func testLockVault_teardownOpensTheGateLast() async throws {
        sut.screen = .vault
        sut.lockVault()
        try await waitUntil { if case .unlock = self.sut.screen { return true }; return false }

        XCTAssertTrue(deps.gate.isOpen, "a sign-in or unlock after the lock must work")
        XCTAssertTrue(deps.gate.isCurrent(deps.gate.begin()))
    }

    /// A flow that starts while the teardown runs (a re-armed Touch ID, Enter on the old unlock
    /// screen) must not count, also after the teardown opened the gate (challenge finding 1).
    func testTokenTakenDuringTheTeardown_isNeverCurrent() async throws {
        sut.screen = .vault
        let reachedTeardown = expectation(description: "teardown reached")
        let release = AsyncGate()
        mockAuth.whileTearingDown = {
            reachedTeardown.fulfill()
            await release.wait()
        }

        sut.lockVault()
        await fulfillment(of: [reachedTeardown], timeout: 2)
        let duringTeardown = deps.gate.begin()
        XCTAssertFalse(deps.gate.isCurrent(duringTeardown))
        await release.open()
        try await waitUntil { self.deps.gate.isOpen }

        XCTAssertFalse(deps.gate.isCurrent(duringTeardown))
    }

    func testSignOut_closesTheGateAtOnce_andOpensItForTheNextSignIn() async throws {
        sut.screen = .vault
        let before = deps.gate.begin()

        sut.signOut()

        XCTAssertFalse(deps.gate.isOpen)
        XCTAssertFalse(deps.gate.isCurrent(before))
        try await waitUntil { if case .login = self.sut.screen { return true }; return false }
        XCTAssertTrue(deps.gate.isOpen)
    }
}

/// A one-shot async latch for holding a mock inside a window.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
