import Combine
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
    @Published var avoidAmbiguous: Bool = false { didSet { generate() } }
    @Published var wordCount: Int = 6 { didSet { generate() } }
    @Published var separator: String = "-" { didSet { generate() } }
    @Published var capitalize: Bool = false { didSet { generate() } }
    @Published var includeNumber: Bool = false { didSet { generate() } }

    // MARK: - Output

    @Published private(set) var generatedValue: String = ""
    @Published private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let provider: RandomnessProvider
    private let generator = PasswordGenerator()
    private let defaults: UserDefaults
    private let clipboard: any ClipboardService
    private var isInitializing = true

    // MARK: - Init

    init(provider: RandomnessProvider, defaults: UserDefaults = .standard, clipboard: any ClipboardService) {
        self.provider = provider
        self.defaults = defaults
        self.clipboard = clipboard
        let config = PasswordGeneratorConfig.load(from: defaults)
        self.mode = config.mode
        self.length = config.length
        self.includeUppercase = config.includeUppercase
        self.includeLowercase = config.includeLowercase
        self.includeDigits = config.includeDigits
        self.includeSymbols = config.includeSymbols
        self.avoidAmbiguous = config.avoidAmbiguous
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
        do {
            let config = currentConfig()
            switch mode {
            case .password:
                generatedValue = try generator.generatePassword(config: config, provider: provider)
            case .passphrase:
                generatedValue = try generator.generatePassphrase(config: config, provider: provider)
            }
            errorMessage = nil
            config.save(to: defaults)
        } catch {
            errorMessage = "Generation failed: \(error.localizedDescription)"
            generatedValue = ""
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
        config.avoidAmbiguous = avoidAmbiguous
        config.wordCount = wordCount
        config.separator = separator
        config.capitalize = capitalize
        config.includeNumber = includeNumber
        return config
    }
}
