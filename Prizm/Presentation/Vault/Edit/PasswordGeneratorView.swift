import AppKit
import SwiftUI

/// Password/passphrase generator popover.
/// Receives a binding to write the generated value into the target field.
struct PasswordGeneratorView: View {

    /// The visible toggle titles list every character of their set (fix-password-generator, D2).
    static var specialToggleTitle: String { "Special (\(String(PasswordGenerator.specialChars)))" }
    static var extendedToggleTitle: String { "Extended special (\(String(PasswordGenerator.extendedSpecialChars)))" }

    @ObservedObject var viewModel: PasswordGeneratorViewModel
    @Binding var targetValue: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Mode picker
            Picker("Mode", selection: $viewModel.mode) {
                Text("Password").tag(PasswordGeneratorConfig.Mode.password)
                Text("Passphrase").tag(PasswordGeneratorConfig.Mode.passphrase)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AccessibilityID.Generator.modePicker)

            Divider()

            // Mode-specific controls
            switch viewModel.mode {
            case .password:
                passwordControls
            case .passphrase:
                passphraseControls
            }

            Divider()

            // Preview area
            previewArea

            Divider()

            // Action row
            actionRow
        }
        .padding()
        .frame(width: 320)
        // An error replaces the preview silently otherwise (§VIII).
        // `initial: true`: the view model generates in its init, so an error can exist on open.
        .onChange(of: viewModel.errorMessage, initial: true) { _, message in
            if let message { Self.announce(message) }
        }
    }

    /// Posts through AppKit, as the edit sheet does, because macOS VoiceOver ignores the priority
    /// that SwiftUI's announcement carries.
    private static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Password controls

    @ViewBuilder
    private var passwordControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Length: \(viewModel.length)")
                    .font(Typography.fieldLabel)
                Spacer()
            }
            Slider(
                value: Binding(
                    get: { Double(viewModel.length) },
                    set: { viewModel.length = Int($0) }
                ),
                in: 5...128,
                step: 1
            )
            .accessibilityIdentifier(AccessibilityID.Generator.lengthSlider)

            Toggle("Uppercase (A–Z)", isOn: $viewModel.includeUppercase)
                .disabled(viewModel.isLastEnabledSet(.uppercase))
                .accessibilityIdentifier(AccessibilityID.Generator.uppercaseToggle)
            Toggle("Lowercase (a–z)", isOn: $viewModel.includeLowercase)
                .disabled(viewModel.isLastEnabledSet(.lowercase))
                .accessibilityIdentifier(AccessibilityID.Generator.lowercaseToggle)
            Toggle("Digits (0–9)", isOn: $viewModel.includeDigits)
                .disabled(viewModel.isLastEnabledSet(.digits))
                .accessibilityIdentifier(AccessibilityID.Generator.digitsToggle)
            // The labels list every character of their set (fix-password-generator, D2).
            Toggle(Self.specialToggleTitle, isOn: $viewModel.includeSymbols)
                .disabled(viewModel.isLastEnabledSet(.symbols))
                .accessibilityLabel("Special characters")
                .accessibilityHint(String(PasswordGenerator.specialChars))
                .accessibilityIdentifier(AccessibilityID.Generator.symbolsToggle)
            Toggle(isOn: $viewModel.includeExtendedSymbols) {
                Text(verbatim: Self.extendedToggleTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(viewModel.isLastEnabledSet(.extendedSymbols))
            // VoiceOver reads a run of punctuation poorly: a name, with the characters as the hint.
            .accessibilityLabel("Extended special characters")
            .accessibilityHint(String(PasswordGenerator.extendedSpecialChars))
            .accessibilityIdentifier(AccessibilityID.Generator.extendedSymbolsToggle)
            Stepper("Minimum numbers: \(viewModel.minNumbers)", value: $viewModel.minNumbers,
                    in: PasswordGeneratorConfig.minimumRange)
                .disabled(!viewModel.isMinNumbersEnabled)
                .help("At least 1 while digits are on.")
                // The visible label carries the value; VoiceOver gets it once, as the value.
                .accessibilityLabel("Minimum numbers")
                .accessibilityValue("\(viewModel.minNumbers)")
                .accessibilityIdentifier(AccessibilityID.Generator.minNumbersStepper)
            Stepper("Minimum special: \(viewModel.minSpecial)", value: $viewModel.minSpecial,
                    in: PasswordGeneratorConfig.minimumRange)
                .disabled(!viewModel.isMinSpecialEnabled)
                .help("At least 1 while special characters are on.")
                .accessibilityLabel("Minimum special")
                .accessibilityValue("\(viewModel.minSpecial)")
                .accessibilityIdentifier(AccessibilityID.Generator.minSpecialStepper)
            Toggle("Avoid ambiguous characters", isOn: $viewModel.avoidAmbiguous)
                .accessibilityIdentifier(AccessibilityID.Generator.avoidAmbiguousToggle)
        }
    }

    // MARK: - Passphrase controls

    @ViewBuilder
    private var passphraseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Words: \(viewModel.wordCount)", value: $viewModel.wordCount,
                    in: PasswordGeneratorConfig.wordCountRange)
                .accessibilityIdentifier(AccessibilityID.Generator.wordCountStepper)
            HStack {
                Text("Separator")
                    .font(Typography.fieldLabel)
                TextField("Separator", text: $viewModel.separator)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .accessibilityIdentifier(AccessibilityID.Generator.separatorField)
            }
            Toggle("Capitalize each word", isOn: $viewModel.capitalize)
                .accessibilityIdentifier(AccessibilityID.Generator.capitalizeToggle)
            Toggle("Include number", isOn: $viewModel.includeNumber)
                .accessibilityIdentifier(AccessibilityID.Generator.includeNumberToggle)
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewArea: some View {
        HStack {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(Typography.fieldValue)
                    .foregroundStyle(.red)
            } else {
                Text(viewModel.generatedValue)
                    .font(Typography.fieldValue.monospaced())
                    .lineLimit(3)
                    .selectableValueText(viewModel.generatedValue)
                    .accessibilityIdentifier(AccessibilityID.Generator.preview)
            }
            Spacer()
            Button {
                viewModel.generate()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Generate new")
            .accessibilityLabel("Generate new password")
            .accessibilityIdentifier(AccessibilityID.Generator.refreshButton)
        }
        .frame(minHeight: 40)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionRow: some View {
        HStack {
            Button("Copy") {
                viewModel.copyToClipboard()
            }
            .disabled(!viewModel.canUse)
            .accessibilityHint("Copies to clipboard")
            .accessibilityIdentifier(AccessibilityID.Generator.copyButton)

            Spacer()

            Button(viewModel.mode == .password ? "Use Password" : "Use Passphrase") {
                targetValue = viewModel.generatedValue
                dismiss()
            }
            .disabled(!viewModel.canUse)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.Generator.useButton)
        }
    }
}
