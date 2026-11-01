import XCTest
import Combine
@testable import Prizm

@MainActor
final class LoginViewModelTests: XCTestCase {

    private var sut:          LoginViewModel!
    private var mockUseCase:  MockLoginUseCase!
    private var gate:         SessionGateImpl!
    private var cancellables: Set<AnyCancellable> = []

    private func makeAccount() -> Account {
        Account(
            userId:            "user-001",
            email:             "alice@example.com",
            name:              nil,
            serverEnvironment: ServerEnvironment(
                base:      URL(string: "https://vault.example.com")!,
                overrides: nil
            )
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        mockUseCase = MockLoginUseCase()
        gate        = SessionGateImpl()
        sut         = LoginViewModel(loginUseCase: mockUseCase, gate: gate)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    // MARK: - Flow token (lock-state-machine, design D2, gap 4)

    /// The token is taken when the user signs in, before the first await: a lock during the
    /// server setup leaves the sign-in with a stale token.
    func testSignIn_takesItsTokenAtTheAction() async throws {
        mockUseCase.stubbedResult = .success(makeAccount())
        sut.serverURL = "https://vault.example.com"
        sut.email     = "alice@example.com"
        sut.password  = "pw"
        let before = gate.begin()

        sut.signIn()
        gate.end()
        gate.open()
        let deadline = ContinuousClock.now + .seconds(2)
        while mockUseCase.receivedFlows.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertEqual(mockUseCase.receivedFlows.first, before, "the token of the moment the user signed in")
        XCTAssertFalse(gate.isCurrent(mockUseCase.receivedFlows[0]))
    }

    /// A sign-in that a lock overtook shows neither the vault nor an error.
    func testSignIn_overtakenByALock_endsOnTheLoginScreenWithoutAMessage() async throws {
        mockUseCase.stubbedResult = .success(makeAccount())
        mockUseCase.whileExecuting = { [gate] in
            gate?.end()
            gate?.open()
        }
        sut.serverURL = "https://vault.example.com"
        sut.email     = "alice@example.com"
        sut.password  = "pw"

        sut.signIn()
        let deadline = ContinuousClock.now + .seconds(2)
        while sut.flowState != .login, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertEqual(sut.flowState, .login)
        XCTAssertNil(sut.errorMessage)
    }

    // MARK: - signIn: password cleared on success

    /// signIn() clears the password field after a successful login (Constitution §III).
    func testSignIn_success_clearsPasswordField() async throws {
        mockUseCase.stubbedResult = .success(makeAccount())
        sut.serverURL = "https://vault.example.com"
        sut.email     = "alice@example.com"
        sut.password  = "SuperSecret1!"

        let exp = expectation(description: "password cleared after sign-in")
        sut.$password
            .dropFirst()
            .filter { $0.isEmpty }
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)

        sut.signIn()

        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(sut.password, "", "Password field must be cleared after successful login")
    }

    /// signIn() clears the password field when the server returns .requiresTwoFactor (Constitution §III).
    func testSignIn_requiresTwoFactor_clearsPasswordField() async throws {
        mockUseCase.stubbedResult = .requiresTwoFactor(.authenticatorApp)
        sut.serverURL = "https://vault.example.com"
        sut.email     = "alice@example.com"
        sut.password  = "SuperSecret1!"

        let exp = expectation(description: "flow transitions to 2FA prompt")
        sut.$flowState
            .dropFirst()
            .filter { $0 == .totpPrompt }
            .first()
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)

        sut.signIn()

        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertEqual(sut.password, "", "Password field must be cleared on 2FA prompt transition")
    }

    /// signIn() does not call the use case when password is empty (matches UI disabled-button guard).
    func testSignIn_emptyPassword_doesNotCallUseCase() {
        sut.serverURL = "https://vault.example.com"
        sut.email     = "alice@example.com"
        sut.password  = ""   // empty — guarded before Task is spawned

        sut.signIn()

        XCTAssertEqual(mockUseCase.executeCallCount, 0,
                       "execute must not be called when password is empty")
    }

    // MARK: - Refused KDF settings (fix-kdf-derivation-and-validation, 3.5)

    /// Both KDF refusals are shown in the login error area, with their own text.
    func testSignIn_refusedKdfSettings_showsTheirMessage() async throws {
        for error in [AuthError.kdfSettingsTooWeak, .invalidKdfSettings] {
            mockUseCase.executeError = error
            sut.serverURL = "https://vault.example.com"
            sut.email     = "alice@example.com"
            sut.password  = "SuperSecret1!"

            let exp = expectation(description: "error shown for \(error)")
            sut.$errorMessage
                .compactMap { $0 }
                .filter { $0 == error.errorDescription }
                .first()
                .sink { _ in exp.fulfill() }
                .store(in: &cancellables)

            sut.signIn()
            await fulfillment(of: [exp], timeout: 2.0)
            XCTAssertEqual(sut.errorMessage, error.errorDescription)
            XCTAssertEqual(sut.flowState, .login)
            cancellables.removeAll()
        }
    }

    // MARK: - cancelTOTP

    /// cancelTOTP() delegates to the use case and resets flow state to .login.
    func testCancelTOTP_callsUseCaseAndResetsState() {
        sut.cancelTOTP()

        XCTAssertTrue(mockUseCase.cancelTOTPCalled,
                      "cancelTOTP must forward to loginUseCase.cancelTOTP()")
        XCTAssertEqual(sut.flowState, .login,
                       "flowState must return to .login after cancelling TOTP")
    }
}
