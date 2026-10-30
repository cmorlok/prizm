import SwiftUI

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

                DetailSectionCard("Notes") {
                    OptionalEditFieldRow(label: "Notes", value: $draft.notes)
                }

                CustomFieldsEditSection(fields: $draft.customFields)
            }
        }
    }

    private func copy(_ value: String) {
        clipboard.copy(value)
    }
}
