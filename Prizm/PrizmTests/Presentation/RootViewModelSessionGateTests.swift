import XCTest
import Combine
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

/// What a lock does to the flows on the lock and login screens (lock-state-machine, design D4–D9).
@MainActor
final class RootViewModelLockFlowTests: XCTestCase {

    private var mockAuth: MockAuthRepository!
    private var deps: MockRootDependencies!
    private var vault: MockVaultRepository!
    private var cancellables: Set<AnyCancellable> = []
    private var sut: RootViewModel!

    private let account = Account(
        userId: "user-001", email: "alice@example.com", name: nil,
        serverEnvironment: ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil)
    )

    override func setUp() async throws {
        try await super.setUp()
        mockAuth = MockAuthRepository()
        mockAuth.stubbedStoredAccount = account
        mockAuth.stubbedLoginResult = .success(account)
        vault = MockVaultRepository()
        deps = MockRootDependencies(auth: mockAuth, vault: vault, defaults: makePrivateDefaults())
        sut = RootViewModel(container: deps)
    }

    private var isLogin: Bool { if case .login = sut.screen { true } else { false } }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - D4/D5: the old unlock view model is ended, a new one shows the lock screen

    func testLockDuringAnUnlock_replacesAndEndsTheUnlockViewModel() async throws {
        let release = AsyncGate()
        mockAuth.whileUnlockingWithPassword = { await release.wait() }
        let old = try XCTUnwrap(sut.unlockVM)
        old.password = "pw"
        old.unlock()
        XCTAssertTrue(sut.canLock, "a running unlock can be locked")

        sut.lockVault()

        XCTAssertTrue(old.isEnded, "ended in the lock's first turn")
        try await waitUntil { self.sut.unlockVM !== old && self.sut.unlockVM != nil }
        XCTAssertFalse(sut.unlockVM === old)
        await release.open()
    }

    func testEndedUnlockViewModel_startsNothing() async throws {
        let old = try XCTUnwrap(sut.unlockVM)
        old.end()
        old.password = "pw"

        old.unlock()
        old.rearmBiometrics()
        old.unlockWithBiometrics()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(mockAuth.receivedFlows.isEmpty, "an ended unlock screen starts no flow")
        XCTAssertEqual(old.biometricContextVersion, 0, "and does not re-arm Touch ID")
    }

    /// The enrollment sheet after an unlock counts as a running unlock: Command-L applies, the
    /// sheet closes, and the lock is no answer to it, so the next unlock offers it again
    /// (design D5; task 3.1; code review C14).
    func testEnrollmentSheetOpen_canBeLocked_andIsOfferedAgain() async throws {
        mockAuth.stubbedDeviceBiometricCapable = true
        let unlock = try XCTUnwrap(sut.unlockVM)
        unlock.password = "pw"
        unlock.unlock()
        try await waitUntil { unlock.showEnrollmentPrompt }
        XCTAssertTrue(sut.canLock)

        sut.lockVault()

        XCTAssertFalse(unlock.showEnrollmentPrompt)
        try await waitUntil { self.sut.unlockVM !== unlock && self.deps.gate.isOpen }
        let next = try XCTUnwrap(sut.unlockVM)
        next.password = "pw"
        next.unlock()
        try await waitUntil { next.showEnrollmentPrompt }
        XCTAssertTrue(next.showEnrollmentPrompt, "offered again after the next unlock")
    }

    /// Spec "Touch ID after a lock during a password unlock": the password unlock that the lock
    /// overtook ends after the user unlocked again with Touch ID, and the new session stays.
    func testStalePasswordUnlockEndingAfterATouchIDUnlock_leavesTheNewSessionAlone() async throws {
        mockAuth.stubbedLoginResult = .success(account)
        mockAuth.stubbedBiometricUnlockAvailable = true
        let release = AsyncGate()
        mockAuth.whileUnlockingWithPassword = { await release.wait() }
        let old = try XCTUnwrap(sut.unlockVM)
        old.password = "pw"
        old.unlock()
        XCTAssertTrue(sut.canLock)

        sut.lockVault()
        try await waitUntil { self.sut.unlockVM !== old && self.deps.gate.isOpen }
        let next = try XCTUnwrap(sut.unlockVM)
        next.unlockWithBiometrics()
        try await waitUntil { if case .vault = self.sut.screen { true } else { false } }
        guard case .vault = sut.screen else { return XCTFail("the Touch ID unlock did not reach the vault") }
        let locksBefore = mockAuth.lockVaultCalledCount

        await release.open()
        try await Task.sleep(for: .milliseconds(100))

        guard case .vault = sut.screen else { return XCTFail("the stale unlock changed the screen: \(sut.screen)") }
        XCTAssertEqual(mockAuth.lockVaultCalledCount, locksBefore, "no teardown of the new session")
        XCTAssertTrue(deps.gate.isCurrent(deps.gate.begin()))
    }

    /// Spec "Command-L on an idle unlock screen": nothing changes and the typed password stays.
    func testCommandLOnAnIdleUnlockScreen_keepsTheTypedPassword() async throws {
        let unlock = try XCTUnwrap(sut.unlockVM)
        unlock.password = "half-typed"

        sut.lockVault()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(sut.unlockVM === unlock)
        XCTAssertFalse(unlock.isEnded)
        XCTAssertEqual(unlock.password, "half-typed")
        XCTAssertEqual(mockAuth.lockVaultCalledCount, 0)
    }

    /// While a password unlock runs, the Touch ID sensor is not armed again (design D9; C14).
    func testWhileAPasswordUnlockRuns_touchIDDoesNotStart() async throws {
        let touch = HeldEmbeddedBiometric(account: account)
        deps.embeddedBiometric = touch
        mockAuth.stubbedBiometricUnlockAvailable = true
        sut = RootViewModel(container: deps)
        let release = AsyncGate()
        mockAuth.whileUnlockingWithPassword = { await release.wait() }
        let unlock = try XCTUnwrap(sut.unlockVM)
        unlock.password = "pw"
        unlock.unlock()
        XCTAssertTrue(unlock.isFlowRunning)

        unlock.triggerEmbeddedBiometricIfAvailable()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(touch.touched)
        await release.open()
    }

    /// An action on the old unlock screen while the lock's teardown runs reaches no auth call: the
    /// screen was ended in the lock's first turn (design D1, D6; C14).
    func testActionOnTheOldUnlockScreenDuringTheTeardown_reachesNothing() async throws {
        sut.screen = .vault
        let old = try XCTUnwrap(sut.unlockVM)
        let release = AsyncGate()
        mockAuth.whileTearingDown = { await release.wait() }

        sut.lockVault()
        old.password = "pw"
        old.unlock()
        old.unlockWithBiometrics()
        try await Task.sleep(for: .milliseconds(50))
        await release.open()
        try await waitUntil { self.deps.gate.isOpen && self.sut.unlockVM !== old }

        XCTAssertTrue(mockAuth.receivedFlows.isEmpty, "no unlock started from the ended screen")
        XCTAssertFalse(mockAuth.unlockWithBiometricsCalled)
    }

    // MARK: - D5: system lock events and Command-L on an idle unlock screen

    func testSystemLockOnAnIdleUnlockScreen_renewsItAndDisarmsTouchID() async throws {
        let old = try XCTUnwrap(sut.unlockVM)
        XCTAssertFalse(sut.canLock, "Command-L does nothing on an idle unlock screen")

        sut.lockForSystemEvent()

        XCTAssertTrue(old.isEnded)
        try await waitUntil { self.sut.unlockVM !== old && self.deps.gate.isOpen }
        XCTAssertNotNil(sut.unlockVM)
        XCTAssertFalse(sut.unlockVM?.isEnded ?? true)
    }

    /// Overlapping locks: every unlock view model but the one shown is ended, so none keeps its
    /// Touch ID context armed (code review C6).
    func testOverlappingLocks_endEveryReplacedUnlockScreen() async throws {
        sut.screen = .vault
        var shown: [UnlockViewModel] = []
        sut.$unlockVM.compactMap { $0 }.sink { shown.append($0) }.store(in: &cancellables)
        let release = AsyncGate()
        mockAuth.whileTearingDown = { await release.wait() }

        sut.lockVault()
        sut.lockForSystemEvent()
        await release.open()
        try await waitUntil { self.deps.gate.isOpen && shown.count == 3 }

        XCTAssertEqual(shown.count, 3, "the launch screen and one per lock")
        XCTAssertTrue(shown.dropLast().allSatisfy(\.isEnded))
        XCTAssertFalse(shown.last?.isEnded ?? true)
    }

    /// The system lock on the unlock screen runs the whole teardown, so keys an unlock loaded just
    /// before it are unloaded too (security review S2, code review C1).
    func testSystemLockOnTheUnlockScreen_unloadsKeysAndClearsTheVault() async throws {
        sut.lockForSystemEvent()

        try await waitUntil { self.mockAuth.lockVaultCalledCount == 1 && self.deps.gate.isOpen }
        XCTAssertEqual(mockAuth.lockVaultCalledCount, 1)
        XCTAssertTrue(vault.clearVaultCalled)
    }

    /// From the accepted finger on, keys can load: Command-L must apply, not wait for the vault
    /// (design D5; S2/C1).
    func testEmbeddedTouchID_afterTheTouch_canBeLocked() async throws {
        let touch = HeldEmbeddedBiometric(account: account)
        deps.embeddedBiometric = touch
        mockAuth.stubbedBiometricUnlockAvailable = true
        sut = RootViewModel(container: deps)
        let unlock = try XCTUnwrap(sut.unlockVM)

        unlock.triggerEmbeddedBiometricIfAvailable()
        try await waitUntil { touch.touched }
        XCTAssertTrue(sut.canLock)
        sut.lockVault()
        XCTAssertTrue(unlock.isEnded)
        await touch.release.open()

        try await waitUntil { self.sut.unlockVM !== unlock && self.deps.gate.isOpen }
        XCTAssertEqual(mockAuth.lockVaultCalledCount, 1)
        guard case .unlock = sut.screen else { return XCTFail("the lock stays: \(sut.screen)") }
    }

    // MARK: - D4: the two-factor prompt

    /// Signs in on a fresh root up to the two-factor prompt.
    private func reachTheTwoFactorPrompt() async throws -> MockLoginUseCase {
        mockAuth.stubbedStoredAccount = nil
        sut = RootViewModel(container: deps)
        let login = deps.mockLoginUseCase
        login.stubbedResult = .requiresTwoFactor(.authenticatorApp)
        sut.loginVM.serverURL = "https://vault.example.com"
        sut.loginVM.email     = "alice@example.com"
        sut.loginVM.password  = "pw"
        sut.loginVM.signIn()
        try await waitUntil { if case .totpPrompt = self.sut.screen { true } else { false } }
        guard case .totpPrompt = sut.screen else { throw XCTSkip("the sign-in did not reach the prompt") }
        return login
    }

    /// Reached by a real sign-in, the prompt is lockable and the lock cancels the pending step in
    /// the use case, which zeroes its keys (design D4; code review C4).
    func testLockOnTheTwoFactorPrompt_cancelsThePendingStep() async throws {
        let login = try await reachTheTwoFactorPrompt()
        XCTAssertTrue(sut.canLock)

        sut.lockVault()
        try await waitUntil { self.deps.gate.isOpen && self.isLogin }

        XCTAssertTrue(login.cancelTOTPCalled)
        XCTAssertTrue(isLogin)
    }

    /// A code submitted just before a lock: its late success shows no vault and its sign-in shows no
    /// error (design D4, D6; code review C4).
    func testLockWhileACodeIsSubmitted_showsNoVault() async throws {
        let login = try await reachTheTwoFactorPrompt()
        login.stubbedResult = .success(account)
        let release = AsyncGate()
        login.whileCompletingTOTP = { await release.wait() }
        sut.loginVM.submitTOTP(code: "123456", rememberDevice: false)
        try await waitUntil { login.completeTOTPCalled }
        XCTAssertTrue(sut.canLock)

        sut.lockVault()
        await release.open()
        try await waitUntil { self.deps.gate.isOpen && self.isLogin }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(isLogin, "no vault after the lock: \(sut.screen)")
        XCTAssertNil(sut.loginVM.errorMessage)
    }

    // MARK: - D1: "Sign in with a different account" is a sign-out of the root

    func testSignInWithADifferentAccount_goesThroughTheRootsSignOut() async throws {
        let unlock = try XCTUnwrap(sut.unlockVM)

        unlock.signInWithDifferentAccount()

        XCTAssertFalse(deps.gate.isOpen, "the gate closes in the same turn")
        try await waitUntil { self.isLogin }
        XCTAssertTrue(mockAuth.signOutCalled)
        XCTAssertTrue(deps.gate.isOpen)
    }

    // MARK: - D9: no competing flow while an unlock runs

    func testWhileAnUnlockRuns_competingActionsAreBlocked() async throws {
        let release = AsyncGate()
        mockAuth.whileUnlockingWithPassword = { await release.wait() }
        let unlock = try XCTUnwrap(sut.unlockVM)
        unlock.password = "pw"
        unlock.unlock()

        XCTAssertTrue(unlock.isFlowRunning)
        unlock.signInWithDifferentAccount()
        XCTAssertTrue(deps.gate.isOpen, "no sign-out while the unlock runs")
        await release.open()
    }
}
