import SwiftUI

// MARK: - AttachmentRowView

/// A single row in the Attachments section card displaying an attachment's name and size.
///
/// When a download found no file on the server, the row says so and offers only Delete
/// (fix-attachment-transfer-flow, D2). Otherwise Open, Save to Disk and Delete show on hover.
/// An org attachment that earlier versions wrapped with the personal key carries a note that only
/// this user can open it (fix-org-attachment-key, D4). A file probably in Prizm's old layout shows
/// a "Prizm format" badge; both offer "Convert", always visible (fix-attachment-file-format, D5).
struct AttachmentRowView: View {

    /// Shown under the file name of an attachment flagged `wrappedWithPersonalKey`.
    static let personalKeyNote = "Only you can open this file"
    /// VoiceOver label of the "Prizm format" badge.
    static let legacyFormatLabel = "Saved in old Prizm format. Other Bitwarden apps can't open it."

    let attachment: Attachment

    // Action callbacks — wired by the parent view.
    // Default no-ops keep task-5 callers (no ViewModel yet) compiling.
    var onOpen:       () -> Void = {}
    var onSaveToDisk: () -> Void = {}
    var onDelete:     () -> Void = {}
    /// True once a download found no file for this attachment on the server.
    var isFileMissing: Bool = false
    var onConvert:    () -> Void = {}
    /// True when the file should be converted (old layout or personal key).
    var canConvert:   Bool = false
    var isConverting: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // File icon + name + size. Not a `Label`: SwiftUI reads a Label as one element, so
            // VoiceOver could not reach the note and the badge inside it (VoiceOver check 2026-10-30).
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
                    if attachment.storedInLegacyPrizmFormat {
                        legacyFormatBadge
                    }
                }
            }

            Spacer()

            if isFileMissing {
                missingFileActions
            } else {
                if canConvert { convertAction }
                if isHovered && !isConverting { normalActions }
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

    // MARK: - Old file layout (fix-attachment-file-format, D5)

    private var legacyFormatBadge: some View {
        Text("Prizm format")
            .font(Typography.utility)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.badgeHorizontal)
            .padding(.vertical, Spacing.badgeVertical)
            .overlay(RoundedRectangle(cornerRadius: Spacing.badgeCornerRadius).stroke(Color.secondary.opacity(0.6)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.legacyFormatLabel)
            .accessibilityIdentifier(AccessibilityID.Attachment.legacyFormatBadge(attachment.id))
    }

    /// Always visible, not only on hover: the user has to find it to repair the file.
    /// The action titles are written in capitals instead of using `.textCase(.uppercase)`: SwiftUI
    /// applies the text case to the button's accessibility label and hint too, and VoiceOver then
    /// spells words like "IT" letter by letter (VoiceOver check 2026-10-30).
    @ViewBuilder
    private var convertAction: some View {
        if isConverting {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Converting")
        } else {
            Button { onConvert() } label: {
                Text(verbatim: "CONVERT")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Convert")
            .accessibilityHint("Uploads the file again in the standard format so other Bitwarden apps can open it.")
            .accessibilityIdentifier(AccessibilityID.Attachment.convertButton(attachment.id))
        }
    }

    // MARK: - Normal actions (hover-activated)

    @ViewBuilder
    private var normalActions: some View {
        HStack(spacing: 8) {
            Button { onOpen() } label: {
                Text(verbatim: "OPEN")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open")
            .accessibilityIdentifier(AccessibilityID.Attachment.openButton(attachment.id))

            Button { onSaveToDisk() } label: {
                Text(verbatim: "SAVE")
                    .font(.headline)
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
