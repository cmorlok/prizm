import Combine
import Foundation
import os.log

// MARK: - LoginFlowState

/// State machine driving the root view transition.
enum LoginFlowState: Equatable {
    case login
    case loading
    case totpPrompt
    case vault
}

// MARK: - LoginViewModel

/// ViewModel for the login + 2FA + sync flow (User Story 1).
///
/// The Presentation layer uses the Domain protocols directly (`AuthRepository`, `SyncUseCase`)
/// so it can report per-step progress to the UI.  No Data-layer types are imported here.
@MainActor
final class LoginViewModel: ObservableObject {

    // MARK: - Published state

    @Published var serverURL:    String = ""
    @Published var email:        String = ""
    @Published var password:     String = ""
    @Published var errorMessage: String?
    @Published private(set) var flowState: LoginFlowState = .login

    // MARK: - Dependencies

    private let loginUseCase: any LoginUseCase
    /// The app's lock fence (lock-state-machine, design D2).
    private let gate: any SessionGate
    /// The running sign-in's token, taken when the user signed in; the two-factor step that
    /// follows belongs to the same sign-in.
    private var signInFlow: FlowToken?
    private let logger = Logger(subsystem: "com.prizm", category: "LoginViewModel")

    // MARK: - Init

    init(loginUseCase: any LoginUseCase, gate: any SessionGate) {
        self.gate = gate
        self.loginUseCase = loginUseCase
    }

    // MARK: - Actions

    /// Validates credentials and initiates the login sequence.
    func signIn() {
        logger.info("Sign-in flow started")
        errorMessage = nil
        flowState    = .loading

        // Convert the password String to Data at this boundary — the only place the
        // String-to-bytes conversion happens. `Data` can be zeroed after the KDF call;
        // `String` cannot (Constitution §III).
        // Reject empty password here to match the UI's disabled-button guard.
        // The Task below must never be spawned with an empty credential.
        guard let passwordData = password.data(using: .utf8), !passwordData.isEmpty else {
            errorMessage = "Invalid password encoding."
            flowState    = .login
            return
        }

        // Taken here, before the first await: a lock during the server setup must refuse this
        // sign-in too (gap 4).
        let flow = gate.begin()
        signInFlow = flow
        Task {
            do {
                let result = try await loginUseCase.execute(
                    serverURL:      serverURL,
                    email:          email,
                    masterPassword: passwordData,
                    flow:           flow
                )
                guard gate.isCurrent(flow) else { return endOvertaken(flow) }

                switch result {
                case .success:
                    // Clear the password field so the plaintext does not linger in
                    // the published property (and therefore the SwiftUI state graph).
                    password  = ""
                    flowState = .vault

                case .requiresTwoFactor(let method):
                    guard case .authenticatorApp = method else {
                        if case .unsupported(let name) = method {
                            throw AuthError.unsupported2FAMethod(name)
                        }
                        throw AuthError.invalidCredentials
                    }
                    password  = ""
                    flowState = .totpPrompt
                }

            } catch let err as AuthError {
                guard gate.isCurrent(flow) else { return endOvertaken(flow) }
                logger.error("Sign-in failed: \(ErrorLog.describe(err), privacy: .public)")
                errorMessage = err.errorDescription
                flowState    = .login
            } catch {
                guard gate.isCurrent(flow) else { return endOvertaken(flow) }
                logger.error("Sign-in failed: \(ErrorLog.describe(error), privacy: .public)")
                errorMessage = error.localizedDescription
                flowState    = .login
            }
        }
    }

    /// Cancels the pending TOTP challenge and returns to the login screen.
    func cancelTOTP() {
        loginUseCase.cancelTOTP()
        flowState = .login
    }

    /// Completes a pending TOTP 2FA challenge.
    func submitTOTP(code: String, rememberDevice: Bool) {
        logger.info("TOTP submission started")
        errorMessage = nil
        flowState    = .loading

        // The two-factor step belongs to the sign-in that reached it and reuses its token (D2).
        guard let flow = signInFlow else {
            logger.fault("TOTP submission without a sign-in")
            flowState = .login
            return
        }
        Task {
            do {
                let _ = try await loginUseCase.completeTOTP(code: code, rememberDevice: rememberDevice, flow: flow)
                guard gate.isCurrent(flow) else { return endOvertaken(flow) }
                flowState = .vault
            } catch let err as AuthError {
                guard gate.isCurrent(flow) else { return endOvertaken(flow) }
                logger.error("TOTP submission failed: \(ErrorLog.describe(err), privacy: .public)")
                errorMessage = err.errorDescription
                flowState    = .totpPrompt
            } catch {
                // No error from a submission that a lock overtook (code review C9).
                guard gate.isCurrent(flow) else { return endOvertaken(flow) }
                logger.error("TOTP submission failed: \(ErrorLog.describe(error), privacy: .public)")
                errorMessage = error.localizedDescription
                flowState    = .totpPrompt
            }
        }
    }

    /// Whether the running sign-in is still current (no lock or sign-out since it started).
    var isFlowCurrent: Bool {
        signInFlow.map { gate.isCurrent($0) } ?? false
    }

    /// Ends a running sign-in or two-factor step because a lock or sign-out started
    /// (lock-state-machine, design D1, D6). Called in the lock's first turn; no-op otherwise.
    func endFlow() {
        switch flowState {
        case .loading:
            endOvertakenSignIn()
        case .totpPrompt:
            loginUseCase.cancelTOTP()
            endOvertakenSignIn()
        case .login, .vault:
            break
        }
    }

    /// The late result of an overtaken `flow`. It changes the screen only while `flow` is still
    /// this view model's latest sign-in: after a lock the user may already have started a new one,
    /// whose spinner and password it must leave alone (code review C2).
    private func endOvertaken(_ flow: FlowToken?) {
        guard flow == signInFlow else {
            logger.info("Late result of an earlier sign-in dropped")
            return
        }
        endOvertakenSignIn()
    }

    /// A sign-in that a lock or sign-out overtook ends quietly on the login screen: no error, no
    /// vault (lock-state-machine, design D6). `RootViewModel` shows the login screen only while the
    /// screen still belongs to the login flow.
    private func endOvertakenSignIn() {
        logger.info("Sign-in ended: a lock or sign-out came first")
        password     = ""
        errorMessage = nil
        flowState    = .login
    }
}
