import SwiftUI

// MARK: - MaskedFieldState

/// Testable value type driving the reveal/mask toggle logic for `MaskedFieldView`.
///
/// Keeping the state logic in a pure struct means it can be unit-tested without
/// rendering a SwiftUI view (FR-026, FR-027).
struct MaskedFieldState {

    /// The eight-bullet placeholder always shown when the field is masked (FR-026).
    static let maskedPlaceholder = "••••••••"

    let value: String
    var isRevealed: Bool

    init(value: String, isRevealed: Bool = false) {
        self.value      = value
        self.isRevealed = isRevealed
    }

    /// The string that should be displayed in the UI.
    var displayValue: String {
        displayValue(peeking: false)
    }

    /// Display value considering an external peek override (e.g. Option-key held).
    func displayValue(peeking: Bool) -> String {
        (isRevealed || peeking) ? value : Self.maskedPlaceholder
    }

    /// Returns a copy with `isRevealed` flipped.
    func toggled() -> MaskedFieldState {
        MaskedFieldState(value: value, isRevealed: !isRevealed)
    }

    /// Returns a new state for a different item, resetting to masked (FR-027).
    func resetForNewItem(value newValue: String) -> MaskedFieldState {
        MaskedFieldState(value: newValue, isRevealed: false)
    }
}

// MARK: - MaskedFieldView

/// A text field that shows eight bullet dots when masked and the real value when revealed.
///
/// The view accepts an optional `String?` value; nil is treated as an empty string.
/// `itemId` drives the `.onChange` that resets `isRevealed` when the parent item changes (FR-027).
///
/// Usage:
/// ```swift
/// MaskedFieldView(label: "Password", value: item.password, itemId: item.id)
/// ```
struct MaskedFieldView: View {

    let label:  String
    let value:  String?
    /// A stable identifier for the current item; changing this resets the reveal state.
    let itemId: String
    /// What VoiceOver calls the field, when `label` is not a name ("History entry from …").
    var accessibilityName: String? = nil
    /// The key of the accessibility identifiers, when `label` is not unique on screen.
    var identifierKey: String? = nil

    @State private var state: MaskedFieldState
    @Environment(OptionKeyMonitor.self) private var optionKeyMonitor

    init(label: String, value: String?, itemId: String,
         accessibilityName: String? = nil, identifierKey: String? = nil) {
        self.label  = label
        self.value  = value
        self.itemId = itemId
        self.accessibilityName = accessibilityName
        self.identifierKey = identifierKey
        _state = State(initialValue: MaskedFieldState(value: value ?? ""))
    }

    /// Plaintext when revealed via toggle OR Option-key peek.
    private var effectiveDisplayValue: String {
        state.displayValue(peeking: optionKeyMonitor.isOptionHeld)
    }

    var body: some View {
        HStack {
            Text(effectiveDisplayValue)
                .font(Typography.fieldValue.monospaced())
                // Without it VoiceOver read the dots after Reveal; with it the password does not
                // stay in the text's character data after Hide either.
                .selectableValueText(effectiveDisplayValue)
                .modifier(OptionalAccessibilityLabel(accessibilityName))
                .accessibilityIdentifier(AccessibilityID.Masked.value(identifierKey ?? label))
            Button {
                state = state.toggled()
            } label: {
                Image(systemName: state.isRevealed ? "eye.slash" : "eye")
                    .imageScale(.medium)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(state.isRevealed ? "Hide" : "Reveal")
            .accessibilityLabel(state.isRevealed ? "Hide \(accessibilityName ?? label)" : "Reveal \(accessibilityName ?? label)")
            .accessibilityIdentifier(AccessibilityID.Masked.toggle(identifierKey ?? label))
        }
        // Reset to masked whenever the parent item changes (FR-027).
        .onChange(of: itemId) { _, _ in
            state = state.resetForNewItem(value: value ?? "")
        }
        // Keep value in sync if the item itself changes while the same itemId is reused.
        .onChange(of: value) { _, newValue in
            state = MaskedFieldState(value: newValue ?? "", isRevealed: state.isRevealed)
        }
    }
}

/// Sets an accessibility label only when one is given, so fields that VoiceOver names from their
/// text keep doing so.
private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?
    init(_ label: String?) { self.label = label }

    func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(label) } else { content }
    }
}
