import LocalAuthentication
import SwiftUI
import os.log

/// macOS Settings window (⌘,).
///
/// Currently contains a Security section with the biometric unlock toggle.
/// The Security section is hidden entirely when the device has no biometrics.
struct SettingsView: View {

    let authRepository: any AuthRepository

    private let logger = Logger(subsystem: "com.prizm", category: "SettingsView")

    private var deviceHasBiometrics: Bool {
        var error: NSError?
        let capable = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        // Skip the routine device states (no hardware, no enrollment, no passcode set) —
        // those are normal, not failures, and would otherwise log on every render (#67).
        if let error, let laError = error as? LAError {
            switch laError.code {
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                break
            default:
                logger.error("Biometric availability check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return capable
    }

    @AppStorage(ClipboardClearDelay.defaultsKey)
    private var clipboardClearDelay: String = ClipboardClearDelay.defaultValue.rawValue

    var body: some View {
        Form {
            Section("Security") {
                if deviceHasBiometrics {
                    BiometricUnlockToggle(authRepository: authRepository)
                }
                // Read by ClipboardServiceImpl at each copy (clipboard-hardening, D2, D4).
                Picker("Clear clipboard", selection: $clipboardClearDelay) {
                    ForEach(ClipboardClearDelay.allCases) { delay in
                        Text(delay.label).tag(delay.rawValue)
                    }
                }
                .help("How long a copied password or code stays on the clipboard. Locking, signing out and quitting Prizm always clear it.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
    }
}
