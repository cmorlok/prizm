import Combine
import Foundation
import os.log

// MARK: - LoginFlowState

/// State machine driving the root view transition.
enum LoginFlowState: Equatable {
    case login
    case loading
    case totpPrompt
    case syncing(message: String)
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
                guard gate.isCurrent(flow) else { return endOvertakenSignIn() }

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
                guard gate.isCurrent(flow) else { return endOvertakenSignIn() }
                logger.error("Sign-in failed: \(ErrorLog.describe(err), privacy: .public)")
                errorMessage = err.errorDescription
                flowState    = .login
            } catch {
                guard gate.isCurrent(flow) else { return endOvertakenSignIn() }
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

        let flow = signInFlow
        Task {
            do {
                let _ = try await loginUseCase.completeTOTP(code: code, rememberDevice: rememberDevice)
                guard let flow, gate.isCurrent(flow) else { return endOvertakenSignIn() }
                flowState = .vault
            } catch let err as AuthError {
                if let flow, !gate.isCurrent(flow) { return endOvertakenSignIn() }
                logger.error("TOTP submission failed: \(ErrorLog.describe(err), privacy: .public)")
                errorMessage = err.errorDescription
                flowState    = .totpPrompt
            } catch {
                logger.error("TOTP submission failed: \(ErrorLog.describe(error), privacy: .public)")
                errorMessage = error.localizedDescription
                flowState    = .totpPrompt
            }
        }
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
