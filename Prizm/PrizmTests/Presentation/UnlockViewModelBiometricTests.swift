import XCTest
import Combine
@testable import Prizm

@MainActor
final class UnlockViewModelBiometricTests: XCTestCase {

    private var sut:          UnlockViewModel!
    private var mockAuth:     MockAuthRepository!
    private var mockSync:     MockSyncUseCase!
    private var defaults:     UserDefaults!
    private var gate:         SessionGateImpl!
    private var cancellables: Set<AnyCancellable> = []

    private let stubAccount = Account(
        userId:            "user-001",
        email:             "alice@example.com",
        name:              nil,
        serverEnvironment: ServerEnvironment(
            base:      URL(string: "https://vault.example.com")!,
            overrides: nil
        )
    )

    override func setUp() async throws {
        try await super.setUp()
        mockAuth = MockAuthRepository()
        mockSync = MockSyncUseCase()
        defaults = makePrivateDefaults()
        gate     = SessionGateImpl()
        sut      = UnlockViewModel(auth: mockAuth, sync: mockSync, account: stubAccount, defaults: defaults, gate: gate)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Embedded Touch ID: a running unlock from the accepted finger on (lock-state-machine, D5)

    func testEmbeddedTouchID_isARunningUnlockFromTheTouchOn() async throws {
        mockAuth.stubbedBiometricUnlockAvailable = true
        let touch = HeldEmbeddedBiometric(account: stubAccount)
        sut = UnlockViewModel(auth: mockAuth, sync: mockSync, account: stubAccount, embeddedBiometric: touch,
                              defaults: defaults, gate: gate)

        sut.triggerEmbeddedBiometricIfAvailable()
        XCTAssertFalse(sut.isFlowRunning, "a sensor waiting for a finger is no running unlock")
        try await waitUntil { touch.touched }

        XCTAssertTrue(sut.isFlowRunning, "keys can load from the touch on")
        await touch.release.open()
    }

    func testEmbeddedTouchID_failingAfterTheTouch_isNoLongerRunning() async throws {
        mockAuth.stubbedBiometricUnlockAvailable = true
        let touch = HeldEmbeddedBiometric(account: stubAccount)
        touch.error = AuthError.biometricUnavailable
        sut = UnlockViewModel(auth: mockAuth, sync: mockSync, account: stubAccount, embeddedBiometric: touch,
                              defaults: defaults, gate: gate)

        sut.triggerEmbeddedBiometricIfAvailable()
        try await waitUntil { touch.touched }
        await touch.release.open()
        try await waitUntil { self.sut.errorMessage != nil }

        XCTAssertFalse(sut.isFlowRunning)
    }

    // MARK: - biometricUnlockAvailable

    func testBiometricUnlockAvailable_reflectsAuthRepository() {
        mockAuth.stubbedBiometricUnlockAvailable = true
        XCTAssertTrue(sut.biometricUnlockAvailable)
        mockAuth.stubbedBiometricUnlockAvailable = false
        XCTAssertFalse(sut.biometricUnlockAvailable)
    }

    // MARK: - unlockWithBiometrics: success

    func testUnlockWithBiometrics_success_callsAuth() {
        mockAuth.stubbedBiometricUnlockAvailable = true
        sut.unlockWithBiometrics()
        let exp = expectation(description: "task runs")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(mockAuth.unlockWithBiometricsCalled)
    }

    // MARK: - unlockWithBiometrics: cancellation

    func testUnlockWithBiometrics_cancellation_noErrorShown() async {
        let cancelError = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(errSecUserCanceled),
            userInfo: nil
        )
        mockAuth.unlockWithBiometricsError = cancelError

        let exp = expectation(description: "flow returns to unlock")
        sut.$flowState
            .filter { $0 == .unlock }
            .dropFirst() // skip initial .unlock
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)

        sut.unlockWithBiometrics()
        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertNil(sut.errorMessage)
    }

    // MARK: - unlockWithBiometrics: re-arm after cancellation

    func testUnlockWithBiometrics_cancellation_rearmsImmediately() async {
        // Cancellation should re-call triggerBiometricUnlockIfAvailable(), which
        // calls unlockWithBiometrics() again — always-armed behaviour (design Decision 2).
        mockAuth.stubbedBiometricUnlockAvailable = true

        let cancelError = NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(errSecUserCanceled),
            userInfo: nil
        )
        // First call cancels; second call also cancels (avoids infinite loop in test).
        // We just need to confirm the second call is made.
        mockAuth.unlockWithBiometricsError = cancelError

        let exp = expectation(description: "re-arm fires second call")
        // Wait for callCount to reach 2.
        var token: AnyCancellable?
        token = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.mockAuth.unlockWithBiometricsCallCount >= 2 {
                    exp.fulfill()
                    token?.cancel()
                }
            }

        sut.unlockWithBiometrics()
        await fulfillment(of: [exp], timeout: 3.0)
        XCTAssertGreaterThanOrEqual(mockAuth.unlockWithBiometricsCallCount, 2)
    }

    // MARK: - unlockWithBiometrics: invalidation

    func testUnlockWithBiometrics_invalidated_showsErrorMessage() async {
        mockAuth.unlockWithBiometricsError = AuthError.biometricInvalidated

        let exp = expectation(description: "error message shown")
        sut.$errorMessage
            .compactMap { $0 }
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)

        sut.unlockWithBiometrics()
        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertNotNil(sut.errorMessage)
    }

    // MARK: - triggerBiometricUnlockIfAvailable

    func testTriggerBiometricUnlock_notAvailable_noOp() async {
        mockAuth.stubbedBiometricUnlockAvailable = false
        sut.triggerBiometricUnlockIfAvailable()
        XCTAssertFalse(mockAuth.unlockWithBiometricsCalled)
    }

    func testTriggerBiometricUnlock_available_callsUnlock() {
        mockAuth.stubbedBiometricUnlockAvailable = true
        sut.triggerBiometricUnlockIfAvailable()
        let exp = expectation(description: "task runs")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(mockAuth.unlockWithBiometricsCalled)
    }

    // MARK: - Enrollment prompt (modal sheet via showEnrollmentPrompt)

    func testDismissEnrollmentPrompt_transitionsToVault() async {
        // Drive enrollment state through the real unlock flow:
        // biometrics capable + not enabled + prompt never shown → showEnrollmentPrompt = true
        mockAuth.stubbedDeviceBiometricCapable = true
        defaults.set(false, forKey: "biometricUnlockEnabled")
        defaults.set(false, forKey: "biometricEnrollmentPromptShown")

        let enrollExp = expectation(description: "enrollment prompt shown")
        sut.$showEnrollmentPrompt
            .filter { $0 == true }
            .first()
            .sink { _ in enrollExp.fulfill() }
            .store(in: &cancellables)

        sut.password = "TestPassword1!"
        sut.unlock()
        await fulfillment(of: [enrollExp], timeout: 3.0)

        let vaultExp = expectation(description: "transitions to vault after dismiss")
        sut.$flowState
            .filter { $0 == .vault }
            .first()
            .sink { _ in vaultExp.fulfill() }
            .store(in: &cancellables)

        sut.dismissEnrollmentPrompt()
        await fulfillment(of: [vaultExp], timeout: 3.0)

        XCTAssertFalse(sut.showEnrollmentPrompt)
        XCTAssertTrue(defaults.bool(forKey: "biometricEnrollmentPromptShown"))
    }

    func testConfirmEnrollBiometric_transitionsToVault() async {
        mockAuth.stubbedDeviceBiometricCapable = true
        defaults.set(false, forKey: "biometricUnlockEnabled")
        defaults.set(false, forKey: "biometricEnrollmentPromptShown")

        let enrollExp = expectation(description: "enrollment prompt shown")
        sut.$showEnrollmentPrompt
            .filter { $0 == true }
            .first()
            .sink { _ in enrollExp.fulfill() }
            .store(in: &cancellables)

        sut.password = "TestPassword1!"
        sut.unlock()
        await fulfillment(of: [enrollExp], timeout: 3.0)

        let vaultExp = expectation(description: "transitions to vault after confirm")
        sut.$flowState
            .filter { $0 == .vault }
            .first()
            .sink { _ in vaultExp.fulfill() }
            .store(in: &cancellables)

        sut.confirmEnrollBiometric()
        await fulfillment(of: [vaultExp], timeout: 3.0)

        XCTAssertFalse(sut.showEnrollmentPrompt)
        XCTAssertTrue(defaults.bool(forKey: "biometricEnrollmentPromptShown"))
    }

    /// Enrollment accepted after a lock: it uses the unlock's (now stale) token, so the auth layer
    /// refuses it, the prompt is not marked as shown and no sync runs (lock-state-machine, D2).
    func testConfirmEnrollBiometric_afterALock_usesTheUnlocksTokenAndMarksNothing() async throws {
        mockAuth.stubbedDeviceBiometricCapable = true
        defaults.set(false, forKey: "biometricUnlockEnabled")
        defaults.set(false, forKey: "biometricEnrollmentPromptShown")
        let enrollExp = expectation(description: "enrollment prompt shown")
        sut.$showEnrollmentPrompt.filter { $0 }.first().sink { _ in enrollExp.fulfill() }.store(in: &cancellables)
        sut.password = "TestPassword1!"
        sut.unlock()
        await fulfillment(of: [enrollExp], timeout: 3.0)
        let unlockFlow = try XCTUnwrap(mockAuth.receivedFlows.first)

        gate.end()
        gate.open()
        sut.confirmEnrollBiometric()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(mockAuth.receivedFlows.last, unlockFlow, "enrollment reuses the unlock's token")
        XCTAssertFalse(defaults.bool(forKey: "biometricEnrollmentPromptShown"), "offered again after the next unlock")
        XCTAssertFalse(mockSync.executeCalled)
        XCTAssertNotEqual(sut.flowState, .vault)
    }

    func testEnrollmentPrompt_reason_isFirstTime_onInitialUnlock() async {
        mockAuth.stubbedDeviceBiometricCapable = true
        defaults.set(false, forKey: "biometricUnlockEnabled")
        defaults.set(false, forKey: "biometricEnrollmentPromptShown")

        let exp = expectation(description: "enrollment prompt shown with .firstTime reason")
        sut.$showEnrollmentPrompt
            .filter { $0 == true }
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)

        sut.password = "TestPassword1!"
        sut.unlock()
        await fulfillment(of: [exp], timeout: 3.0)

        XCTAssertEqual(sut.enrollmentReason, .firstTime)
    }
}
