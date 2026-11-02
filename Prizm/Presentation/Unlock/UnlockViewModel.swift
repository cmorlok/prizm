import Combine
import Foundation
import LocalAuthentication
import os.log

// MARK: - UnlockFlowState

enum UnlockFlowState: Equatable {
    case unlock
    case loading
    case syncing(message: String)
    case vault
}

// MARK: - UnlockViewModel

/// ViewModel for the vault unlock screen (User Story 2).
///
/// The user has a stored session; this screen re-derives the vault key from the
/// master password locally (no network call) then re-syncs the vault.
@MainActor
final class UnlockViewModel: ObservableObject {

    // MARK: - Published state

    @Published var password:        String = ""
    @Published var errorMessage:    String?
    @Published private(set) var flowState: UnlockFlowState = .unlock
    @Published var showEnrollmentPrompt: Bool = false
    @Published private(set) var enrollmentReason: EnrollmentReason = .firstTime
    /// An unlock is under way: from the password or Touch ID request through the token refresh,
    /// the enrollment prompt and the sync, until the vault or a failure. A lock applies then, and
    /// competing actions on this screen are blocked (lock-state-machine, design D5, D9).
    @Published private(set) var isFlowRunning = false
    /// Set by `end()`: this screen was replaced by a lock or sign-out and starts nothing any more.
    private(set) var isEnded = false
    /// Signs out through the root, which closes the session gate first (design D1). Set by
    /// `RootViewModel` for every unlock view model it holds; this type never signs out itself, so
    /// no sign-out can skip the gate (code review C7).
    var onSignOutRequested: (() -> Void)?

    // MARK: - Dependencies

    private let auth:             any AuthRepository
    private let sync:             any SyncUseCase
    private let account:          Account
    private let embeddedBiometric: (any EmbeddedBiometricUnlock)?
    /// The Touch ID preferences; required so tests pass a private store (fix-biometric-test-isolation, D1).
    private let defaults:         UserDefaults
    /// The app's lock fence (lock-state-machine, design D2).
    private let gate:             any SessionGate
    /// The running unlock's token, taken when it started (password entered, Touch ID requested or
    /// armed). The enrollment prompt and the sync after it belong to the same unlock.
    private var unlockFlow:       FlowToken?
    private let logger = Logger(subsystem: "com.prizm", category: "UnlockViewModel")

    /// Tracks whether the last biometric attempt failed with invalidation,
    /// so the enrollment prompt can show the re-enroll copy.
    private var lastBiometricInvalidated = false

    // MARK: - Biometric context (LAAuthenticationView re-arming)

    /// The current `LAContext` shared with the embedded `LAAuthenticationView`.
    /// Replaced with a fresh instance on each re-arm so the view can re-authenticate.
    @Published private(set) var biometricContext = LAContext()

    /// Incremented on every re-arm so SwiftUI recreates `EmbeddedTouchIDView` via `.id()`.
    @Published private(set) var biometricContextVersion = 0

    // MARK: - Init

    init(
        auth: any AuthRepository,
        sync: any SyncUseCase,
        account: Account,
        embeddedBiometric: (any EmbeddedBiometricUnlock)? = nil,
        defaults: UserDefaults,
        gate: any SessionGate
    ) {
        self.gate              = gate
        self.auth              = auth
        self.sync              = sync
        self.account           = account
        self.embeddedBiometric = embeddedBiometric
        self.defaults          = defaults
    }

    // MARK: - Derived properties

    /// The stored email, shown read-only in the UI (FR-003).
    var email: String { account.email }

    /// Whether biometric unlock is available for this device and session.
    var biometricUnlockAvailable: Bool { auth.biometricUnlockAvailable }

    // MARK: - Actions

    func unlock() {
        // One unlock at a time: Enter after an accepted Touch ID starts no second one (C10).
        guard !isEnded, !isFlowRunning else { return }
        logger.info("Unlock flow started")
        errorMessage = nil
        flowState    = .loading

        // Convert the password String to Data at this boundary so the KDF stack
        // receives `Data` that can be zeroed after use (Constitution §III).
        guard let passwordData = password.data(using: .utf8) else {
            errorMessage = "Invalid password encoding."
            flowState    = .unlock
            return
        }

        let flow = beginUnlockFlow()
        isFlowRunning = true
        // No Touch ID unlock alongside the password one (design D9); re-armed if this one fails.
        biometricContext.invalidate()
        Task {
            do {
                _ = try await auth.unlockWithPassword(passwordData, flow: flow)
                guard gate.isCurrent(flow) else { return endOvertakenUnlock() }
                // Clear the password field after a successful unlock so the plaintext
                // does not linger in the published property.
                password = ""
                await checkEnrollmentOrSync(flow: flow)
            } catch where !gate.isCurrent(flow) {
                endOvertakenUnlock()
            } catch let err as AuthError {
                logger.error("Unlock failed: \(ErrorLog.describe(err), privacy: .public)")
                errorMessage = err.errorDescription
                flowState    = .unlock
                endFailedFlow()
            } catch {
                logger.error("Unlock failed: \(ErrorLog.describe(error), privacy: .public)")
                errorMessage = error.localizedDescription
                flowState    = .unlock
                endFailedFlow()
            }
        }
    }

    /// Attempts biometric unlock. On success, proceeds to sync.
    /// On cancellation, re-arms the sensor immediately (always-armed behaviour —
    /// design Decision 2). On lockout or invalidation, shows an error and stops.
    func unlockWithBiometrics() {
        guard !isEnded, !isFlowRunning else { return }
        let flow = beginUnlockFlow()
        isFlowRunning = true
        Task {
            do {
                _ = try await auth.unlockWithBiometrics(flow: flow)
                guard gate.isCurrent(flow) else { return endOvertakenUnlock() }
                lastBiometricInvalidated = false
                await checkEnrollmentOrSync(flow: flow)
            } catch where !gate.isCurrent(flow) {
                // Overtaken by a lock or sign-out: no error, and no re-arm (design D4).
                endOvertakenUnlock()
            } catch let err as AuthError where err == .biometricInvalidated {
                lastBiometricInvalidated = true
                errorMessage = err.errorDescription
                flowState = .unlock
                isFlowRunning = false
                // Intentionally NOT re-arming — invalidation requires password entry.
            } catch let err as AuthError where err == .biometricItemNotFound {
                // Keychain item deleted externally — degrade silently, no error shown.
                // biometricUnlockAvailable will return false now (flag cleared in repo).
                _ = err
                flowState = .unlock
                isFlowRunning = false
            } catch let err as NSError
                where err.domain == NSOSStatusErrorDomain && err.code == Int(errSecUserCanceled) {
                // User cancelled — re-arm immediately so the sensor is always ready.
                // No error shown; password field stays available in parallel.
                flowState = .unlock
                isFlowRunning = false
                triggerBiometricUnlockIfAvailable()
            } catch {
                // Lockout or other failure — show the error, stop re-arming.
                errorMessage = error.localizedDescription
                flowState = .unlock
                isFlowRunning = false
            }
        }
    }

    /// Triggers biometric unlock via the embedded `LAAuthenticationView` path.
    /// Called from `.task(id: biometricContextVersion)` in `UnlockView` so the
    /// `LAAuthenticationView` is guaranteed to be in the window before
    /// `evaluatePolicy` is called — no system modal appears.
    func triggerEmbeddedBiometricIfAvailable() {
        guard !isEnded, !isFlowRunning, biometricUnlockAvailable, let provider = embeddedBiometric else { return }
        // Taken when the sensor is armed, not when the finger touches it: a lock while the view
        // waits makes this unlock stale (design D2).
        let flow = beginUnlockFlow()
        Task {
            do {
                _ = try await provider.unlockWithBiometrics(context: biometricContext, flow: flow) {
                    // The finger was accepted and keys can load from here: from now to the vault
                    // this is a running unlock that a lock applies to (design D5).
                    if gate.isCurrent(flow) { isFlowRunning = true }
                }
                guard gate.isCurrent(flow) else { return endOvertakenUnlock() }
                lastBiometricInvalidated = false
                await checkEnrollmentOrSync(flow: flow)
            } catch where !gate.isCurrent(flow) {
                // Overtaken by a lock or sign-out: no error, and no re-arm (design D4).
                endOvertakenUnlock()
            } catch let err as AuthError where err == .biometricInvalidated {
                isFlowRunning = false
                lastBiometricInvalidated = true
                errorMessage = err.errorDescription
                flowState    = .unlock
            } catch let err as AuthError where err == .biometricItemNotFound {
                // Keychain item deleted externally — degrade silently, no error shown.
                _ = err
                isFlowRunning = false
                flowState = .unlock
            } catch let laError as LAError {
                isFlowRunning = false
                switch laError.code {
                case .biometryLockout:
                    // Locked out — show error, stop re-arming.
                    errorMessage = laError.localizedDescription
                    flowState    = .unlock
                default:
                    // Cancellation or transient failure — re-arm silently.
                    rearmBiometrics()
                }
            } catch {
                isFlowRunning = false
                errorMessage = error.localizedDescription
                flowState    = .unlock
            }
        }
    }

    /// Triggers biometric unlock if available; no-op otherwise.
    /// Kept for use when `embeddedBiometric` is nil (test/legacy path).
    func triggerBiometricUnlockIfAvailable() {
        guard !isEnded, biometricUnlockAvailable else { return }
        unlockWithBiometrics()
    }

    /// Replaces `biometricContext` with a fresh `LAContext` and increments the version
    /// counter so `UnlockView` recreates `EmbeddedTouchIDView` via `.id()`.
    func rearmBiometrics() {
        // An ended screen never re-arms (design D4), and a running unlock has none beside it (D9).
        guard !isEnded, !isFlowRunning else { return }
        biometricContext        = LAContext()
        biometricContextVersion += 1
    }

    /// Called when the user accepts the enrollment prompt.
    ///
    /// Uses the unlock's token, not a new one: an enrollment accepted after a lock stores nothing,
    /// marks nothing, and is offered again after the next unlock (design D2).
    func confirmEnrollBiometric() {
        guard !isEnded, let flow = unlockFlow else { return }
        Task {
            do {
                try await auth.enableBiometricUnlock(flow: flow)
            } catch where !gate.isCurrent(flow) {
                // Refused because a lock or sign-out came first: expected, not an error (C12).
                logger.info("Enable biometric unlock skipped: a lock or sign-out came first")
            } catch {
                logger.error("Enable biometric unlock failed: \(ErrorLog.describe(error), privacy: .public)")
            }
            showEnrollmentPrompt = false
            guard gate.isCurrent(flow) else { return endOvertakenUnlock() }
            defaults.set(true, forKey: BiometricPreferenceKey.enrollmentPromptShown)
            await performSync(flow: flow)
        }
    }

    /// Called when the user dismisses the enrollment prompt without enabling.
    func dismissEnrollmentPrompt() {
        guard !isEnded else { return }
        showEnrollmentPrompt = false
        guard let flow = unlockFlow, gate.isCurrent(flow) else { return endOvertakenUnlock() }
        defaults.set(true, forKey: BiometricPreferenceKey.enrollmentPromptShown)
        Task { await performSync(flow: flow) }
    }

    /// Clears session and returns to the login screen (FR-039).
    func signInWithDifferentAccount() {
        // Disabled in the view while an unlock runs (design D9); checked here as well.
        guard !isEnded, !isFlowRunning else { return }
        logger.info("User switching to different account")
        guard let onSignOutRequested else {
            logger.fault("Sign in with a different account: no root sign-out is connected")
            return
        }
        onSignOutRequested()
    }

    // MARK: - Private

    /// After a successful unlock, checks whether to show the enrollment prompt sheet
    /// before proceeding to sync.
    ///
    /// Uses `auth.deviceBiometricCapable` (not `biometricUnlockAvailable`) so the check
    /// is mockable in tests and independent of the UserDefaults enabled flag.
    /// Takes the token of an unlock that starts now (design D2).
    private func beginUnlockFlow() -> FlowToken {
        let flow = gate.begin()
        unlockFlow = flow
        return flow
    }

    /// An unlock that a lock or sign-out overtook ends quietly: no error, no sync, no vault.
    private func endOvertakenUnlock() {
        logger.info("Unlock ended: a lock or sign-out came first")
        errorMessage  = nil
        flowState     = .unlock
        isFlowRunning = false
    }

    /// A password unlock failed (wrong password, network): Touch ID is offered again.
    private func endFailedFlow() {
        isFlowRunning = false
        rearmBiometrics()
    }

    /// Whether the running unlock is still current (not ended, no lock or sign-out since it began).
    var isFlowCurrent: Bool {
        guard !isEnded, let unlockFlow else { return false }
        return gate.isCurrent(unlockFlow)
    }

    /// Ends this unlock screen for good: a lock or sign-out replaced it (lock-state-machine,
    /// design D4, D6). Runs in the lock's first turn, so the sensor stops listening for the old
    /// flow and the enrollment sheet closes before anything else happens.
    ///
    /// - Intentionally NOT done: re-arming. The non-embedded Touch ID path makes its own context in
    ///   `readBiometric(key:)`, which cannot be invalidated from here; it is fenced by its token.
    func end() {
        isEnded              = true
        isFlowRunning        = false
        showEnrollmentPrompt = false
        biometricContext.invalidate()
    }

    private func checkEnrollmentOrSync(flow: FlowToken) async {
        let capable        = auth.deviceBiometricCapable
        let alreadyEnabled = defaults.bool(forKey: BiometricPreferenceKey.unlockEnabled)
        let promptShown    = defaults.bool(forKey: BiometricPreferenceKey.enrollmentPromptShown)

        if capable && !alreadyEnabled && !promptShown {
            enrollmentReason    = lastBiometricInvalidated ? .reEnrollAfterInvalidation : .firstTime
            showEnrollmentPrompt = true
            // performSync() will be called by confirmEnrollBiometric() or dismissEnrollmentPrompt().
            return
        }
        await performSync(flow: flow)
    }

    private func performSync(flow: FlowToken) async {
        guard gate.isCurrent(flow) else { return endOvertakenUnlock() }
        flowState = .syncing(message: "Preparing…")
        do {
            _ = try await sync.execute(flow: flow, progress: { [weak self] message in
                Task { @MainActor [weak self] in
                    // A report that arrives after the vault was shown changes nothing (C11).
                    guard let self, self.isFlowRunning, self.gate.isCurrent(flow) else { return }
                    self.flowState = .syncing(message: message)
                }
            })
        } catch {
            logger.error("Post-unlock sync failed (non-fatal): \(ErrorLog.describe(error), privacy: .public)")
        }
        guard gate.isCurrent(flow) else { return endOvertakenUnlock() }
        isFlowRunning = false
        flowState = .vault
    }
}
