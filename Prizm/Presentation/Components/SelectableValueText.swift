import SwiftUI

// MARK: - Selectable value text

extension View {

    /// Makes a value text selectable and keeps what VoiceOver reads equal to what is shown.
    ///
    /// A selectable `Text` keeps the text it was created with, both in its accessibility value and
    /// in its character data (`AXNumberOfCharacters`, `AXStringForRange`), which VoiceOver also
    /// reads. SwiftUI reuses the text when another item is selected, a value is revealed or edited,
    /// or the generator produces a new one. So the value is set explicitly (also for a `spoken`
    /// form such as "March 2027"), and the shown text is the view's identity, which rebuilds the
    /// character data (fix-ui-journey-findings D3, fix-selectable-text-voiceover D1).
    /// `.transition(.identity)` keeps the old and the new text from existing side by side during an
    /// animated change, where VoiceOver could still reach the old one.
    func selectableValueText(_ shown: String, spokenAs spoken: String? = nil) -> some View {
        self
            .textSelection(.enabled)
            .accessibilityValue(spoken ?? shown)
            .id(shown)
            .transition(.identity)
    }
}
