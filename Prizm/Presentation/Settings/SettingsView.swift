import LocalAuthentication
import SwiftUI
import os.log

/// macOS Settings window (⌘,).
///
/// A Security section (biometric unlock, clipboard clearing) and a Privacy section (website icons).
/// The biometric toggle is hidden when the device has no biometrics.
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
                logger.error("Biometric availability check failed: \(ErrorLog.describe(error), privacy: .public)")
            }
        }
        return capable
    }

    @AppStorage(ClipboardClearDelay.defaultsKey)
    private var clipboardClearDelay: String = ClipboardClearDelay.defaultValue.rawValue

    // Read by FaviconLoader at each request and by FaviconView (fix-website-icons-privacy, D2).
    @AppStorage(WebsiteIconSettings.showIconsKey)
    private var showWebsiteIcons: Bool = WebsiteIconSettings.showIconsDefault

    @AppStorage(WebsiteIconSettings.allowOtherServicesKey)
    private var allowOtherServices: Bool = WebsiteIconSettings.allowOtherServicesDefault

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
            Section("Privacy") {
                Toggle("Show website icons", isOn: $showWebsiteIcons)
                    .help("Icons are loaded from your server's icon service, which may contact the websites.")
                    // A grouped-form switch exposes its title as a separate text, not as its own
                    // label; name the switch itself (§VIII; seen in the UI test 2026-10-30).
                    .accessibilityLabel("Show website icons")
                    .accessibilityIdentifier(AccessibilityID.Settings.showWebsiteIcons)
                Toggle("Allow icons from other services", isOn: $allowOtherServices)
                    .help("If your server sends icon requests on to another service, Prizm follows it. That service sees the website addresses and your IP address.")
                    .disabled(!showWebsiteIcons)
                    .accessibilityLabel("Allow icons from other services")
                    .accessibilityIdentifier(AccessibilityID.Settings.allowOtherServices)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
    }
}
