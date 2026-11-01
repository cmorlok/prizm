import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - SSHKeyCreateActions

/// What the create sheet can do with the key (openspec change `ssh-key-import-and-generation`,
/// design D6). The edit sheet passes none: an existing key is never replaced.
struct SSHKeyCreateActions {
    let generate: () -> Void
    let importFromClipboard: () -> Void
    let importFromFile: (URL) -> Void
    /// The file picker failed; the view model logs it and shows a message.
    let importFailed: (Error) -> Void
    /// The refusal message of the last import, or nil.
    let message: String?
    /// Changes with every refusal, also when the message stays the same.
    let refusalCount: Int
}

// MARK: - SSHKeyEditForm

/// Edit form for SSH Key vault items.
///
/// Private key, public key and fingerprint are read-only, as in the official clients: the three are
/// written together, and no server derives the fingerprint (Vaultwarden 1.37.4 hides an SSH key
/// without one, `src/db/models/cipher.rs:298-308`). They use the detail view's rows, so the private
/// key stays masked with reveal and copy (openspec change `fix-ssh-key-roundtrip`, design D2).
/// Notes and custom fields stay editable.
struct SSHKeyEditForm: View {

    @Binding var draft: DraftSSHKeyContent
    /// The item's id, which the rows use like the detail view's rows do.
    let itemId: String
    /// Generate and import, on the create sheet only.
    var createActions: SSHKeyCreateActions? = nil

    @State private var showFileImporter = false

    /// The app's one clipboard service, so copies from this sheet are cleared like any other.
    @Environment(ClipboardServiceImpl.self) private var clipboard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                DetailSectionCard("SSH Key") {
                    FieldRowView(label: "Private Key", value: draft.privateKey, itemId: itemId,
                                 isMasked: true, onCopy: copy)
                    Divider()
                    FieldRowView(label: "Public Key", value: draft.publicKey, itemId: itemId, onCopy: copy)
                    Divider()
                    FieldRowView(label: "Fingerprint", value: draft.keyFingerprint, itemId: itemId, onCopy: copy)
                }

                if let createActions {
                    keyActions(createActions)
                }

                DetailSectionCard("Notes") {
                    OptionalEditFieldRow(label: "Notes", value: $draft.notes)
                }

                CustomFieldsEditSection(fields: $draft.customFields, itemType: .sshKey)
            }
        }
    }

    @ViewBuilder
    private func keyActions(_ actions: SSHKeyCreateActions) -> some View {
        VStack(alignment: .leading, spacing: Spacing.headerGap) {
            HStack(spacing: Spacing.headerGap) {
                Button("Generate new key", action: actions.generate)
                    .accessibilityHint("Replaces the private key, public key and fingerprint")
                Menu("Import key…") {
                    Button("From clipboard", action: actions.importFromClipboard)
                    Button("From file…") { showFileImporter = true }
                }
                .fixedSize()
                .accessibilityHint("Imports an unencrypted OpenSSH Ed25519 private key")
                Spacer()
            }
            if let message = actions.message {
                Text(message)
                    .font(Typography.utility)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.pageMargin)
        .padding(.bottom, Spacing.cardBottom)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): actions.importFromFile(url)
            case .failure(let error): actions.importFailed(error)
            }
        }
        // A refused import is announced when its message appears (Constitution §VIII), at high
        // priority: at default priority the closing Import menu cut it off (hand check 2026-10-30).
        .onChange(of: actions.refusalCount) {
            if let message = actions.message { Self.announce(message) }
        }
    }

    /// Posts through AppKit: macOS VoiceOver ignores the priority that SwiftUI's
    /// `AccessibilityNotification.Announcement` carries (same as `ItemEditView.announce`).
    private static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private func copy(_ value: String) {
        clipboard.copy(value)
    }
}
