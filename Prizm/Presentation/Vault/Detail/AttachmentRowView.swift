import SwiftUI

// MARK: - AttachmentRowView

/// A single row in the Attachments section card displaying an attachment's name and size.
///
/// When a download found no file on the server, the row says so and offers only Delete
/// (fix-attachment-transfer-flow, D2). Otherwise Open, Save to Disk and Delete show on hover.
/// An org attachment that earlier versions wrapped with the personal key carries a note that only
/// this user can open it (fix-org-attachment-key, D4).
struct AttachmentRowView: View {

    /// Shown under the file name of an attachment flagged `wrappedWithPersonalKey`.
    static let personalKeyNote = "Only you can open this file"

    let attachment: Attachment

    // Action callbacks — wired by the parent view.
    // Default no-ops keep task-5 callers (no ViewModel yet) compiling.
    var onOpen:       () -> Void = {}
    var onSaveToDisk: () -> Void = {}
    var onDelete:     () -> Void = {}
    /// True once a download found no file for this attachment on the server.
    var isFileMissing: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // File icon + name + size. Not a `Label`: SwiftUI reads a Label as one element, so
            // VoiceOver could not reach the note inside it (VoiceOver check 2026-10-30).
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName)
                            .font(Typography.fieldValue)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(attachment.sizeName)
                            .font(Typography.listSubtitle)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    if attachment.wrappedWithPersonalKey {
                        personalKeyNote
                    }
                }
            }

            Spacer()

            if isFileMissing {
                missingFileActions
            } else if isHovered {
                normalActions
            }
        }
        .padding(.vertical, Spacing.rowVertical)
        .padding(.horizontal, Spacing.rowHorizontal)
        .contentShape(Rectangle())
        .onHover { hovering in
            optionalAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityIdentifier(AccessibilityID.Attachment.row(attachment.id))
    }

    // MARK: - Wrapped with the personal key (fix-org-attachment-key, D4)

    private var personalKeyNote: some View {
        Label(Self.personalKeyNote, systemImage: "person.badge.key")
            .font(Typography.utility)
            .foregroundStyle(.orange)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.personalKeyNote)
            .accessibilityHint("It was saved with your personal key, so other members of the organization can't open it.")
            .accessibilityIdentifier(AccessibilityID.Attachment.personalKeyNote(attachment.id))
    }

    // MARK: - Normal actions (hover-activated)

    @ViewBuilder
    private var normalActions: some View {
        HStack(spacing: 8) {
            Button { onOpen() } label: {
                Text("open")
                    .font(.headline)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open")
            .accessibilityIdentifier(AccessibilityID.Attachment.openButton(attachment.id))

            Button { onSaveToDisk() } label: {
                Text("save")
                    .font(.headline)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save to Disk")
            .accessibilityHint("Saves file to your chosen location")
            .accessibilityIdentifier(AccessibilityID.Attachment.saveButton(attachment.id))

            Button { onDelete() } label: {
                Image(systemName: "trash")
                    .imageScale(.medium)
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
            .accessibilityIdentifier(AccessibilityID.Attachment.deleteButton(attachment.id))
        }
        .transition(.opacity)
    }

    // MARK: - File missing on the server (fix-attachment-transfer-flow, D2)

    /// Always visible, not only on hover: the only thing left to do with such an entry is delete it.
    @ViewBuilder
    private var missingFileActions: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(AttachmentRowViewModel.missingFileNote)
                .font(Typography.utility)
                .foregroundStyle(.orange)
                .accessibilityIdentifier(AccessibilityID.Attachment.missingFileNote(attachment.id))
            Button { onDelete() } label: {
                Image(systemName: "trash")
                    .imageScale(.medium)
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
            .accessibilityHint("Deletes this attachment entry")
            .accessibilityIdentifier(AccessibilityID.Attachment.deleteButton(attachment.id))
        }
    }
}
