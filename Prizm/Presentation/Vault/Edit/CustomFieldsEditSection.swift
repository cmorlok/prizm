import SwiftUI

// MARK: - CustomFieldsEditSection

/// The Custom Fields card of the edit sheet: fields can be added, renamed, removed and moved up or
/// down; a field's type cannot change once it exists, as in official clients (openspec change
/// `vault-browsing-parity`, design D6). The card is always shown, so a field can be added to an
/// item that has none.
///
/// Hidden-type fields are masked by default with a reveal toggle. Fields of a type Prizm does not
/// know can be renamed, moved and removed; their value is never shown or edited.
struct CustomFieldsEditSection: View {

    /// Binding into the parent draft's `customFields` array.
    @Binding var fields: [DraftCustomField]
    /// Decides which field types can be added (linked only for logins, cards and identities) and
    /// which targets a linked field offers.
    let itemType: ItemType

    var body: some View {
        DetailSectionCard("Custom Fields") {
            ForEach(fields) { field in
                if let index = fields.firstIndex(where: { $0.id == field.id }) {
                    if index > 0 { Divider() }
                    CustomFieldEditRow(
                        field: $fields[index],
                        index: index,
                        count: fields.count,
                        linkOptions: LinkedFieldId.options(for: itemType),
                        onMove: { move(field.id, by: $0) },
                        onRemove: { fields.removeField(id: field.id) }
                    )
                }
            }
            if !fields.isEmpty { Divider() }
            addMenu
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Text") { add(.text) }
            Button("Hidden") { add(.hidden) }
            Button("Checkbox") { add(.boolean) }
            if !LinkedFieldId.options(for: itemType).isEmpty {
                Button("Linked") { add(.linked) }
            }
        } label: {
            Label("Add Field", systemImage: "plus")
                .font(Typography.fieldValue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.Edit.addCustomField)
        .padding(.vertical, Spacing.rowVertical)
        .padding(.horizontal, Spacing.rowHorizontal)
    }

    private func add(_ type: CustomFieldType) {
        fields.append(DraftCustomField(newOfType: type, for: itemType))
    }

    /// Moves the field and tells VoiceOver where it went, as the official form does.
    private func move(_ id: UUID, by offset: Int) {
        guard let position = fields.moveField(id: id, by: offset) else { return }
        let name = CustomFieldLabels.accessibilityName(of: fields[position])
        Self.announce(CustomFieldLabels.moved(name, to: position + 1, of: fields.count))
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
}

// MARK: - CustomFieldEditRow

/// One custom field: move buttons, name, value editor by type, and Remove, laid out like the
/// website rows of `LoginEditForm`.
private struct CustomFieldEditRow: View {

    @Binding var field: DraftCustomField
    let index: Int
    let count: Int
    let linkOptions: [LinkedFieldId]
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    /// Controls reveal state for Hidden fields (masked by default — spec §4.9).
    @State private var isRevealed = false

    private var accessibilityName: String { CustomFieldLabels.accessibilityName(of: field) }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if count > 1 { moveButtons }

            VStack(alignment: .leading, spacing: 2) {
                TextField("Field name", text: $field.nameText,
                          prompt: Text(field.name == nil ? CustomFieldLabels.unnamed : "Field name"))
                    .font(Typography.fieldLabel)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Name of \(accessibilityName)")
                    .accessibilityIdentifier(AccessibilityID.Edit.customFieldName(index))

                if field.isMissingName {
                    Text(CustomFieldLabels.nameRequired)
                        .font(Typography.utility)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(AccessibilityID.Edit.customFieldNameRequired(index))
                }

                valueEditor
            }
            Spacer()

            if field.type == .hidden {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(isRevealed ? "Hide" : "Reveal")
                .accessibilityLabel(isRevealed ? "Hide \(accessibilityName)" : "Reveal \(accessibilityName)")
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove field")
            .accessibilityLabel("Remove \(accessibilityName)")
            .accessibilityIdentifier(AccessibilityID.Edit.customFieldRemove(index))
        }
        .padding(.vertical, Spacing.rowVertical)
        .padding(.horizontal, Spacing.rowHorizontal)
    }

    private var moveButtons: some View {
        VStack(spacing: 2) {
            Button { onMove(-1) } label: {
                Image(systemName: "chevron.up")
                    .font(Typography.utility)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Move \(accessibilityName) up")
            .accessibilityIdentifier(AccessibilityID.Edit.customFieldMoveUp(index))
            .disabled(index == 0)

            Button { onMove(1) } label: {
                Image(systemName: "chevron.down")
                    .font(Typography.utility)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Move \(accessibilityName) down")
            .accessibilityIdentifier(AccessibilityID.Edit.customFieldMoveDown(index))
            .disabled(index == count - 1)
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch field.type {
        case .hidden:
            editableHiddenField

        case .boolean:
            // Boolean fields use a Toggle; value is "true" or "false" string.
            Toggle(
                isOn: Binding(
                    get:  { field.value == "true" },
                    set:  { field.value = $0 ? "true" : "false" }
                )
            ) {
                EmptyView()
            }
            .labelsHidden()
            .accessibilityLabel(accessibilityName)

        case .linked:
            linkedPicker

        case .unknown:
            // A type Prizm does not know is kept unchanged and not edited (design D3 of
            // fix-read-mapping-lossless-fields); its value is not shown here, as it may be secret.
            Text(CustomFieldLabels.unsupportedType)
                .font(Typography.fieldValue)
                .foregroundStyle(.secondary)

        case .text:
            TextField(
                accessibilityName,
                text: Binding(
                    get:  { field.value ?? "" },
                    set:  { field.value = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("Value")
            )
            .accessibilityLabel("Value of \(accessibilityName)")
            .font(Typography.fieldValue)
            .textFieldStyle(.plain)
        }
    }

    /// The field a linked field mirrors. A target Prizm does not know (or none) stays selected
    /// until the user picks one; it cannot be picked again (fix-read-mapping-lossless-fields, D3).
    private var linkedPicker: some View {
        Picker("Linked to", selection: $field.linkedId) {
            ForEach(linkOptions, id: \.self) { option in
                Text(option.displayName).tag(LinkedFieldId?.some(option))
            }
            if let current = field.linkedId, !linkOptions.contains(current) {
                Text(current.displayName).tag(field.linkedId).selectionDisabled()
            } else if field.linkedId == nil {
                Text(LinkedFieldId.unknownDisplayName).tag(LinkedFieldId?.none).selectionDisabled()
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("\(accessibilityName) linked to")
    }

    @ViewBuilder
    private var editableHiddenField: some View {
        if isRevealed {
            TextField(
                accessibilityName,
                text: Binding(
                    get:  { field.value ?? "" },
                    set:  { field.value = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text("Value")
            )
            .accessibilityLabel("Value of \(accessibilityName)")
            .font(Typography.fieldValue.monospaced())
            .textFieldStyle(.plain)
        } else {
            Text(MaskedFieldState.maskedPlaceholder)
                .font(Typography.fieldValue.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Value of \(accessibilityName), hidden")
        }
    }
}
