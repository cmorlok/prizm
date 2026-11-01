import SwiftUI

// MARK: - CustomFieldsSection

/// Renders a list of custom fields for any item type (FR-029).
///
/// - `text` fields: visible, copyable.
/// - `hidden` fields: masked, revealable.
/// - `boolean` fields: checkbox icon (read-only in v1).
/// - `linked` fields: shown as read-only label with linked field name.
/// - fields of a type Prizm does not know: masked and revealable, read-only, labelled as unsupported
///   (fix-read-mapping-lossless-fields, design D3). Masked because a newer type may hold a secret.
struct CustomFieldsSection: View {

    let fields: [CustomField]
    let itemId: String
    let onCopy: (String) -> Void

    var body: some View {
        if fields.isEmpty { EmptyView() } else {
            ForEach(fields.indices, id: \.self) { index in
                let field = fields[index]
                customFieldRow(field)
                if index < fields.indices.last! {
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func customFieldRow(_ field: CustomField) -> some View {
        switch field.type {
        case .text:
            FieldRowView(
                label:  field.displayName,
                value:  field.value,
                itemId: itemId,
                onCopy: onCopy
            )

        case .hidden:
            FieldRowView(
                label:    field.displayName,
                value:    field.value,
                itemId:   itemId,
                isMasked: true,
                onCopy:   onCopy
            )

        case .boolean:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.displayName)
                        .font(Typography.fieldLabel)
                        .foregroundStyle(.secondary)
                    Image(systemName: field.value == "true" ? "checkmark.square" : "square")
                        .imageScale(.medium)
                }
                Spacer()
            }
            .padding(.vertical, Spacing.rowVertical)
            .padding(.horizontal, Spacing.rowHorizontal)

        case .linked:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.displayName)
                        .font(Typography.fieldLabel)
                        .foregroundStyle(.secondary)
                    Text("→ \(field.linkedId?.displayName ?? LinkedFieldId.unknownDisplayName)")
                        .font(Typography.fieldValue)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, Spacing.rowVertical)
            .padding(.horizontal, Spacing.rowHorizontal)

        case .unknown:
            FieldRowView(
                label:    field.unsupportedLabel,
                value:    field.value,
                itemId:   itemId,
                isMasked: true,
                onCopy:   onCopy
            )
        }
    }
}

// MARK: - Labels

/// Texts for values that the server can hold but Prizm cannot interpret
/// (openspec change `fix-read-mapping-lossless-fields`, design D2 and D3).
extension CustomField {
    /// The field's name, or "Unnamed field" for a field stored without one.
    var displayName: String { name ?? CustomFieldLabels.unnamed }

    /// Row label of a field whose type Prizm does not know.
    var unsupportedLabel: String { CustomFieldLabels.unsupported(displayName) }
}

extension DraftCustomField {
    var displayName: String { name ?? CustomFieldLabels.unnamed }
}

extension LinkedFieldId {
    /// Shown when a linked field has no target at all.
    static let unknownDisplayName = LinkedFieldId.unknown(0).displayName
}

enum CustomFieldLabels {
    static let unnamed = "Unnamed field"
    static let unsupportedType = "Unsupported field type"

    static func unsupported(_ name: String) -> String { "\(name) (\(unsupportedType))" }

    // MARK: Editing (vault-browsing-parity, design D6)

    /// The VoiceOver name of a field added in the sheet that has no name yet.
    static let newField = "New field"
    static let nameRequired = "A name is required."

    /// The name VoiceOver uses for a field's controls ("Move PIN up").
    static func accessibilityName(of field: DraftCustomField) -> String {
        if let name = field.name, !name.isEmpty { return name }
        return field.isNew ? newField : unnamed
    }

    /// Announced after a move, as the official form does: "PIN moved to position 2 of 4".
    static func moved(_ name: String, to position: Int, of count: Int) -> String {
        "\(name) moved to position \(position) of \(count)"
    }
}
