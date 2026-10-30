import AppKit
import SwiftUI

// MARK: - LoginView

/// The initial authentication screen (User Story 1, FR-001–FR-010).
///
/// Collects server URL, email, and master password, then initiates the login flow
/// via `LoginViewModel`. The view itself is stateless — all logic lives in the VM.
struct LoginView: View {

    @ObservedObject var viewModel: LoginViewModel

    /// Focus state used to advance through fields on Return.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case serverURL, email, password
    }

    var body: some View {
        VStack(spacing: 24) {
            // MARK: Header
            VStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(Typography.screenIcon)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Prizm")
                    .font(Typography.screenHeading)
                Text("Self-hosted vault")
                    .font(Typography.fieldLabel)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            // MARK: Form fields
            VStack(spacing: 12) {
                // Server URL — FR-001
                LabeledContent("Server URL") {
                    TextField("https://vault.example.com", text: $viewModel.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .serverURL)
                        .autocorrectionDisabled()
                        .onSubmit { focusedField = .email }
                        .accessibilityIdentifier(AccessibilityID.Login.serverURLField)
                }

                // Email — FR-003
                LabeledContent("Email") {
                    TextField("you@example.com", text: $viewModel.email)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .email)
                        .autocorrectionDisabled()
                        .onSubmit { focusedField = .password }
                        .accessibilityIdentifier(AccessibilityID.Login.emailField)
                }

                // Master password — FR-005
                LabeledContent("Master password") {
                    SecureField("Enter master password", text: $viewModel.password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .password)
                        .onSubmit { signIn() }
                        .accessibilityIdentifier(AccessibilityID.Login.passwordField)
                }
            }
            .labeledContentStyle(.vertical)
            .frame(maxWidth: 360)

            // MARK: Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(Typography.screenBody)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .transition(.opacity)
                    .accessibilityIdentifier(AccessibilityID.Login.errorMessage)
            }

            // MARK: Sign In button — FR-007
            Button(action: signIn) {
                if case .loading = viewModel.flowState {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Sign In")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(width: 360)
            .disabled(isSignInDisabled)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityIdentifier(AccessibilityID.Login.signInButton)

            Spacer()
        }
        .padding(.horizontal, Spacing.screenHorizontal)
        .padding(.bottom, 32)
        .frame(minWidth: 480, minHeight: 400)
        // A refused sign-in shows this screen again after "Signing in…"; focus goes to the password,
        // not back to the server URL (hand check 2026-10-30, Constitution §VIII).
        .onAppear {
            focusedField = viewModel.errorMessage == nil ? .serverURL : .password
        }
        // The error is announced once VoiceOver has read the new screen and the focused field: posted
        // on appear, even at high priority, it was dropped during the screen change (hand check).
        .task {
            guard let error = viewModel.errorMessage else { return }
            try? await Task.sleep(for: Self.errorAnnouncementDelay)
            if viewModel.errorMessage == error { Self.announce(error) }
        }
        .onChange(of: viewModel.errorMessage) { _, error in
            if let error { Self.announce(error) }
        }
    }

    // MARK: - Announcements

    /// Long enough for VoiceOver to finish the screen change (VoiceOver hand check 2026-10-30).
    private static let errorAnnouncementDelay: Duration = .seconds(1)

    /// Posts through AppKit at high priority: macOS VoiceOver ignores the priority that SwiftUI's
    /// `AccessibilityNotification.Announcement` carries, and a default one is cut off when focus
    /// moves (same as `ItemEditView.announce`).
    private static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    // MARK: - Private helpers

    private var isSignInDisabled: Bool {
        if case .loading = viewModel.flowState { return true }
        return viewModel.serverURL.isEmpty || viewModel.email.isEmpty || viewModel.password.isEmpty
    }

    private func signIn() {
        guard !isSignInDisabled else { return }
        viewModel.signIn()
    }
}


