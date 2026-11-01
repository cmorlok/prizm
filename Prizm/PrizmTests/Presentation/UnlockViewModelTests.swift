import XCTest
import Combine
@testable import Prizm

@MainActor
final class UnlockViewModelTests: XCTestCase {

    private var sut:          UnlockViewModel!
    private var mockAuth:     MockAuthRepository!
    private var mockSync:     MockSyncUseCase!
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
        gate     = SessionGateImpl()
        sut      = UnlockViewModel(auth: mockAuth, sync: mockSync, account: stubAccount,
                                   defaults: makePrivateDefaults(), gate: gate)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    // MARK: - Flow token (lock-state-machine, design D2)

    func testUnlock_passesTheTokenOfTheAction() async throws {
        mockAuth.stubbedLoginResult = .success(stubAccount)
        let before = gate.begin()
        sut.password = "pw"

        sut.unlock()
        try await waitUntil { !self.mockAuth.receivedFlows.isEmpty }

        XCTAssertEqual(mockAuth.receivedFlows.first, before)
    }

    /// The sync after the unlock runs with the unlock's token (design D8; code review C5).
    func testUnlock_syncsWithItsFlow() async throws {
        mockAuth.stubbedLoginResult = .success(stubAccount)
        sut.password = "pw"

        sut.unlock()
        try await waitUntil { !self.mockSync.receivedFlows.isEmpty }

        XCTAssertEqual(mockSync.receivedFlows, mockAuth.receivedFlows)
    }

    /// A second Enter while an unlock runs starts no second unlock (code review C10).
    func testUnlock_whileAnUnlockRuns_startsNoSecond() async throws {
        mockAuth.stubbedLoginResult = .success(stubAccount)
        let release = AsyncGate()
        mockAuth.whileUnlockingWithPassword = { await release.wait() }
        sut.password = "pw"
        sut.unlock()
        try await waitUntil { !self.mockAuth.receivedFlows.isEmpty }

        sut.password = "pw"
        sut.unlock()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mockAuth.receivedFlows.count, 1)
        await release.open()
    }

    /// A sync progress report that arrives after the vault was reported does not bring
    /// "Syncing" back over the vault (code review C11).
    func testLateSyncProgress_afterTheVault_isIgnored() async throws {
        mockAuth.stubbedLoginResult = .success(stubAccount)
        mockSync.progressMessage = "Decrypting…"
        sut.password = "pw"

        sut.unlock()
        // Waits for the end of the flow, not for `.vault`: the late report would replace it.
        try await waitUntil { self.mockSync.executeCalled && !self.sut.isFlowRunning }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(sut.flowState, .vault)
    }

    /// Every wait has a deadline: a test that never sees its state fails instead of hanging the
    /// test host.
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// An unlock that a lock overtook after the keys loaded neither syncs nor reports the vault.
    func testUnlock_overtakenByALock_doesNotSyncOrReportTheVault() async throws {
        mockAuth.stubbedLoginResult = .success(stubAccount)
        mockAuth.whileUnlockingWithPassword = { [gate] in
            gate?.end()
            gate?.open()
        }
        var states: [UnlockFlowState] = []
        sut.$flowState.sink { states.append($0) }.store(in: &cancellables)
        sut.password = "pw"

        sut.unlock()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(states.contains(.vault))
        XCTAssertFalse(states.contains { if case .syncing = $0 { return true }; return false })
        XCTAssertEqual(mockSync.executeCount, 0)
    }

    // MARK: - unlock: password cleared on success

    /// unlock() clears the password field after a successful unlock (Constitution §III).
    func testUnlock_success_clearsPasswordField() async throws {
        mockAuth.stubbedLoginResult = .success(stubAccount)
        sut.password = "SuperSecret1!"

        let exp = expectation(description: "password cleared after unlock")
        sut.$password
            .dropFirst()
            .filter { $0.isEmpty }
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)

        sut.unlock()

        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(sut.password, "", "Password field must be cleared after successful unlock")
    }

    // MARK: - unlock: wrong password

    /// Configures a wrong-password unlock and waits for the async Task to complete.
    /// Both wrong-password assertions share this setup to avoid duplication.
    private func runUnlockWithWrongPassword() async {
        mockAuth.unlockWithPasswordError = AuthError.invalidCredentials
        sut.password = "WrongPassword!"

        let exp = expectation(description: "unlock fails with error message")
        sut.$errorMessage
            .compactMap { $0 }
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)

        sut.unlock()
        await fulfillment(of: [exp], timeout: 2.0)
    }

    /// unlock() does NOT clear the password field on wrong password so the user can correct it.
    func testUnlock_wrongPassword_retainsPasswordField() async throws {
        await runUnlockWithWrongPassword()
        XCTAssertEqual(sut.password, "WrongPassword!",
                       "Password field must be retained on failed unlock so the user can correct it")
    }

    /// unlock() surfaces an error message on wrong password.
    func testUnlock_wrongPassword_setsErrorMessage() async throws {
        await runUnlockWithWrongPassword()
        XCTAssertNotNil(sut.errorMessage, "An error message must be shown on failed unlock")
    }

    /// A refused KDF setting is shown in the unlock error area with its own text
    /// (fix-kdf-derivation-and-validation, 3.5).
    func testUnlock_refusedKdfSettings_showsTheirMessage() async throws {
        for error in [AuthError.kdfSettingsTooWeak, .invalidKdfSettings] {
            mockAuth.unlockWithPasswordError = error
            sut.password = "SuperSecret1!"

            let exp = expectation(description: "error shown for \(error)")
            sut.$errorMessage
                .compactMap { $0 }
                .filter { $0 == error.errorDescription }
                .first()
                .sink { _ in exp.fulfill() }
                .store(in: &cancellables)

            sut.unlock()
            await fulfillment(of: [exp], timeout: 2.0)
            cancellables.removeAll()
        }
    }

    // MARK: - email property

    /// email property returns the stored account's email address.
    func testEmail_returnsStoredAccountEmail() {
        XCTAssertEqual(sut.email, "alice@example.com")
    }
}
