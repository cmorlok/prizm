import Combine
import os
import SwiftUI

/// ViewModel for the password generator popover.
/// Owns the config and the generated value; copies go through the app's `ClipboardService`.
/// Instantiated as `@StateObject` inside `EditFieldRow` so plaintext
/// is released when the popover closes (design D7, Constitution §III).
@MainActor
final class PasswordGeneratorViewModel: ObservableObject {

    // MARK: - Published config properties

    @Published var mode: PasswordGeneratorConfig.Mode = .password { didSet { generate() } }
    @Published var length: Int = 16 { didSet { generate() } }
    @Published var includeUppercase: Bool = true { didSet { generate() } }
    @Published var includeLowercase: Bool = true { didSet { generate() } }
    @Published var includeDigits: Bool = true { didSet { generate() } }
    @Published var includeSymbols: Bool = true { didSet { generate() } }
    @Published var includeExtendedSymbols: Bool = false { didSet { generate() } }
    @Published var avoidAmbiguous: Bool = false { didSet { generate() } }
    @Published var minNumbers: Int = 1 { didSet { generate() } }
    @Published var minSpecial: Int = 0 { didSet { generate() } }
    @Published var wordCount: Int = 6 { didSet { generate() } }
    @Published var separator: String = "-" { didSet { generate() } }
    @Published var capitalize: Bool = false { didSet { generate() } }
    @Published var includeNumber: Bool = false { didSet { generate() } }

    // MARK: - Output

    @Published private(set) var generatedValue: String = ""
    @Published private(set) var errorMessage: String?
    /// The strength of the current settings; nil while there is no value (generator-strength-meter).
    @Published private(set) var strength: GeneratorStrength?

    /// `true` when there is a value to copy or use; never an empty one (fix-password-generator, D5).
    var canUse: Bool { errorMessage == nil && !generatedValue.isEmpty }

    /// The character sets of password mode, for the last-enabled-set lock.
    enum CharacterSetKind: CaseIterable {
        case uppercase, lowercase, digits, symbols, extendedSymbols
    }

    /// `true` when `kind` is on and every other set is off: switching it off would leave nothing.
    func isLastEnabledSet(_ kind: CharacterSetKind) -> Bool {
        isEnabled(kind) && CharacterSetKind.allCases.filter(isEnabled).count == 1
    }

    var isMinNumbersEnabled: Bool { includeDigits }
    var isMinSpecialEnabled: Bool { includeSymbols }

    private func isEnabled(_ kind: CharacterSetKind) -> Bool {
        switch kind {
        case .uppercase:       return includeUppercase
        case .lowercase:       return includeLowercase
        case .digits:          return includeDigits
        case .symbols:         return includeSymbols
        case .extendedSymbols: return includeExtendedSymbols
        }
    }

    // MARK: - Dependencies

    private let provider: RandomnessProvider
    private let generator: PasswordGenerator
    private static let logger = Logger(subsystem: "com.prizm", category: "PasswordGenerator")
    private let defaults: UserDefaults
    private let clipboard: any ClipboardService
    private var isInitializing = true

    // MARK: - Init

    init(provider: RandomnessProvider, defaults: UserDefaults = .standard, clipboard: any ClipboardService,
         generator: PasswordGenerator = PasswordGenerator()) {
        self.provider = provider
        self.generator = generator
        self.defaults = defaults
        self.clipboard = clipboard
        let config = PasswordGeneratorConfig.load(from: defaults)
        self.mode = config.mode
        self.length = config.length
        self.includeUppercase = config.includeUppercase
        self.includeLowercase = config.includeLowercase
        self.includeDigits = config.includeDigits
        self.includeSymbols = config.includeSymbols
        self.includeExtendedSymbols = config.includeExtendedSymbols
        self.avoidAmbiguous = config.avoidAmbiguous
        self.minNumbers = config.minNumbers
        self.minSpecial = config.minSpecial
        self.wordCount = config.wordCount
        self.separator = config.separator
        self.capitalize = config.capitalize
        self.includeNumber = config.includeNumber
        isInitializing = false
        generate()
    }

    // MARK: - Actions

    func generate() {
        guard !isInitializing else { return }
        let config = currentConfig()
        if mode == .password, config.effectiveLength > length {
            // Minimums need more characters than the slider allows: raise the slider, so what is
            // shown is what is generated. The `didSet` of `length` generates again.
            length = config.effectiveLength
            return
        }
        do {
            switch mode {
            case .password:
                generatedValue = try generator.generatePassword(config: config, provider: provider)
            case .passphrase:
                generatedValue = try generator.generatePassphrase(config: config, provider: provider)
            }
            errorMessage = nil
            // The word list is read only for passphrases; its failure is caught below like the
            // generator's own.
            let wordListSize = mode == .passphrase ? try generator.wordList().count : 0
            strength = GeneratorStrength.of(config, wordListSize: wordListSize)
            config.save(to: defaults)
        } catch PasswordGeneratorError.wordListUnavailable {
            // A missing bundled resource is a build defect (design D5).
            Self.logger.fault("Passphrase word list unavailable")
            errorMessage = PasswordGeneratorError.wordListUnavailable.localizedDescription
            generatedValue = ""
            strength = nil
        } catch {
            Self.logger.error("Generation failed: \(String(describing: type(of: error)), privacy: .public)")
            // Every other failure comes from the random source (the provider's own error type has
            // no user-facing text).
            errorMessage = (error as? PasswordGeneratorError ?? .randomSourceFailed).localizedDescription
            generatedValue = ""
            strength = nil
        }
    }

    /// Copies the generated value through the app's clipboard service, so it is hidden from
    /// clipboard history and cleared even after this view model is gone (clipboard-hardening).
    func copyToClipboard() {
        clipboard.copy(generatedValue)
    }

    // MARK: - Private

    private func currentConfig() -> PasswordGeneratorConfig {
        var config = PasswordGeneratorConfig()
        config.mode = mode
        config.length = length
        config.includeUppercase = includeUppercase
        config.includeLowercase = includeLowercase
        config.includeDigits = includeDigits
        config.includeSymbols = includeSymbols
        config.includeExtendedSymbols = includeExtendedSymbols
        config.avoidAmbiguous = avoidAmbiguous
        config.minNumbers = minNumbers
        config.minSpecial = minSpecial
        config.wordCount = wordCount
        config.separator = separator
        config.capitalize = capitalize
        config.includeNumber = includeNumber
        return config
    }
}
