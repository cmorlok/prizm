import SwiftUI

// MARK: - CardEditForm

/// Edit form for Card vault items.
///
/// Mirrors the layout of `CardDetailView`. Brand and expiry month are pickers with the values
/// official Bitwarden clients store; a stored value that matches none of them stays selectable as
/// "<value> (custom)" so it is not lost (card-field-normalisation).
struct CardEditForm: View {

    @Binding var draft: DraftCardContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                DetailSectionCard("Card Details") {
                    OptionalEditFieldRow(label: "Cardholder Name", value: $draft.cardholderName)
                    Divider()
                    CardOptionPickerRow(label: "Brand", value: $draft.brand,
                                        options: CardBrand.options, canonical: CardBrand.canonical(for:))
                    Divider()
                    // Detecting the brand on every number edit, as the web form does.
                    OptionalEditFieldRow(label: "Number", value: Binding(
                        get: { draft.number },
                        set: { draft.setNumber($0) }
                    ))
                    Divider()
                    CardOptionPickerRow(label: "Expiry Month", value: $draft.expMonth,
                                        options: ExpiryMonth.options, canonical: ExpiryMonth.canonical(for:))
                    Divider()
                    OptionalEditFieldRow(label: "Expiry Year", value: $draft.expYear, prompt: "YYYY")
                    Divider()
                    OptionalEditFieldRow(label: "Security Code", value: $draft.code)
                }

                DetailSectionCard("Notes") {
                    OptionalEditFieldRow(label: "Notes", value: $draft.notes)
                }

                CustomFieldsEditSection(fields: $draft.customFields)
            }
        }
    }
}

// MARK: - CardOptionPickerRow

/// A labelled menu picker over official card values, with "Not set" and, only when the stored
/// value matches none of them, a "<value> (custom)" entry.
private struct CardOptionPickerRow: View {

    let label: String
    @Binding var value: String?
    let options: [CardBrand.Option]
    let canonical: (String?) -> CardFieldValue

    var body: some View {
        let current = canonical(value)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Typography.fieldLabel)
                .foregroundStyle(.secondary)
            HStack {
                Picker(selection: Binding(
                    get: { current },
                    set: { value = $0.stored }
                )) {
                    Text("Not set").tag(CardFieldValue.notSet)
                    ForEach(options, id: \.value) { option in
                        Text(option.displayName).tag(CardFieldValue.known(option.value))
                    }
                    if case .custom(let custom) = current {
                        Text("\(custom) (custom)").tag(current)
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .font(Typography.fieldValue)
                .accessibilityLabel(label)
                Spacer()
            }
        }
        .padding(.vertical, Spacing.rowVertical)
        .padding(.horizontal, Spacing.rowHorizontal)
    }
}
