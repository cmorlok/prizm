import SwiftUI

// MARK: - FieldRowView

/// A single labeled field row with hover-activated action buttons (FR-023, FR-025).
///
/// Shows a label + value and reveals copy/reveal/open-in-browser controls on hover.
/// Background highlights on hover to indicate interactivity (FR-023).
///
/// For secret fields (password, card number, etc.) pass `isMasked: true` to show
/// a `MaskedFieldView` instead of plain text; the reveal button will be included automatically.
///
/// Usage:
/// ```swift
/// FieldRowView(label: "Username", value: item.username, itemId: item.id)
/// FieldRowView(label: "Password", value: item.password, itemId: item.id, isMasked: true)
/// FieldRowView(label: "Website", value: uri.uri, itemId: item.id, url: URILaunchTarget.url(for: uri))
/// ```
struct FieldRowView: View {

    let label:    String
    let value:    String?
    let itemId:   String
    var isMasked: Bool  = false
    var isMultiLine: Bool = false
    var url:      URL?  = nil
    var onCopy:   ((String) -> Void)? = nil
    /// What VoiceOver reads instead of `value`, when the shown text reads badly ("03 / 2027").
    var spokenValue: String? = nil
    /// The label's font; the field name by default, a smaller date in the password history.
    var labelFont: Font = Typography.fieldValue
    /// What VoiceOver calls the field when `label` is not a name (the history's dates).
    var accessibilityName: String? = nil
    /// The key of the accessibility identifiers when `label` is not unique on screen.
    var identifierKey: String? = nil
    /// What the copy hint says is copied; the label by default.
    var copiedThing: String? = nil

    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Field content
            if isMasked {
                Text(label)
                    .font(labelFont)
                Spacer()
                hoverActions
                MaskedFieldView(label: label, value: value, itemId: itemId,
                                accessibilityName: accessibilityName, identifierKey: identifierKey)
                    .accessibilityHint(copyHint)
            } else if isMultiLine {
                VStack(alignment: .leading, spacing: 2) {
                    if !label.isEmpty {
                        Text(label)
                            .font(Typography.fieldValue)
                    }
                    Text(value ?? "—")
                        .font(Typography.fieldValue.monospaced())
                        .selectableValueText(value ?? "—", spokenAs: spokenValue)
                        .accessibilityHint(copyHint)
                }
                Spacer()
                hoverActions
            } else {
                Text(label)
                    .font(Typography.fieldValue)
                Spacer()
                hoverActions
                Text(value ?? "—")
                    .font(Typography.fieldValue.monospaced())
                    .lineLimit(1)
                    .selectableValueText(value ?? "—", spokenAs: spokenValue)
                    .accessibilityHint(copyHint)
                browserLink
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, Spacing.rowHorizontal)
        .contentShape(Rectangle())
        .onTapGesture { copyValue() }
        .onHover { hovering in
            optionalAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityIdentifier(AccessibilityID.Field.row(identifierKey ?? label))
    }

    /// On the value elements only: on the row it would also reach the "Open" button, whose own
    /// hint is "Opens in browser" (safe-uri-launch).
    private var copyHint: String {
        value != nil && !(value?.isEmpty ?? true) ? "Copies \(copiedThing ?? label) to clipboard" : ""
    }

    private func copyValue() {
        guard let copyValue = value, !copyValue.isEmpty else { return }
        onCopy?(copyValue)
        optionalAnimation(.easeInOut(duration: 0.1)) { showCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            optionalAnimation(.easeInOut(duration: 0.1)) { showCopied = false }
        }
    }

    @ViewBuilder
    private var hoverActions: some View {
        if isHovered || showCopied {
            if value != nil, !(value?.isEmpty ?? true) {
                Text(showCopied ? "copied" : "copy")
                    .font(.headline)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentColor)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var browserLink: some View {
        if let link = url {
            Link(destination: link) {
                Image(systemName: "arrow.up.right.square")
                    .imageScale(.medium)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Open in browser")
            .accessibilityLabel("Open \(label)")
            .accessibilityHint("Opens in browser")
            .accessibilityIdentifier(AccessibilityID.Field.openButton(label))
        }
    }
}
