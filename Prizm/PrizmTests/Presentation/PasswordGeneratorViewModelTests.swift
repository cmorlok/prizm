import SwiftUI
import XCTest
@testable import Prizm

@MainActor
final class PasswordGeneratorViewModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var provider: MockRandomnessProvider!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "PasswordGeneratorViewModelTests")!
        defaults.removePersistentDomain(forName: "PasswordGeneratorViewModelTests")
        provider = MockRandomnessProvider()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "PasswordGeneratorViewModelTests")
        try await super.tearDown()
    }

    func testInit_generatesValueImmediately() {
        let vm = PasswordGeneratorViewModel(provider: provider, defaults: defaults, clipboard: ClipboardServiceImpl(pasteboard: FakePasteboard()))
        XCTAssertFalse(vm.generatedValue.isEmpty)
    }

    func testConfigChange_triggersRegeneration() {
        let vm = PasswordGeneratorViewModel(provider: provider, defaults: defaults, clipboard: ClipboardServiceImpl(pasteboard: FakePasteboard()))
        let first = vm.generatedValue
        vm.length = 32
        // Value should change (different length = different output).
        XCTAssertNotEqual(vm.generatedValue.count, first.count)
    }

    func testModeSwitch_triggersRegeneration() {
        let vm = PasswordGeneratorViewModel(provider: provider, defaults: defaults, clipboard: ClipboardServiceImpl(pasteboard: FakePasteboard()))
        vm.mode = .passphrase
        XCTAssertTrue(vm.generatedValue.contains("-"))
    }

    func testCopyToClipboard_writesToPasteboard() {
        let pasteboard = FakePasteboard()
        let vm = PasswordGeneratorViewModel(provider: provider, defaults: defaults, clipboard: ClipboardServiceImpl(pasteboard: pasteboard))
        vm.copyToClipboard()
        XCTAssertEqual(pasteboard.string, vm.generatedValue)
        XCTAssertTrue(pasteboard.concealed)
    }

    func testSettingsPersisted_toUserDefaults() {
        let vm = PasswordGeneratorViewModel(provider: provider, defaults: defaults, clipboard: ClipboardServiceImpl(pasteboard: FakePasteboard()))
        vm.length = 42
        vm.mode = .passphrase

        // Load a new VM from the same defaults — should restore.
        let provider2 = MockRandomnessProvider()
        let vm2 = PasswordGeneratorViewModel(provider: provider2, defaults: defaults, clipboard: ClipboardServiceImpl(pasteboard: FakePasteboard()))
        XCTAssertEqual(vm2.length, 42)
        XCTAssertEqual(vm2.mode, .passphrase)
    }

    func testDefaultsRestored_onFirstLaunch() {
        let vm = PasswordGeneratorViewModel(provider: provider, defaults: defaults, clipboard: ClipboardServiceImpl(pasteboard: FakePasteboard()))
        XCTAssertEqual(vm.mode, .password)
        XCTAssertEqual(vm.length, 16)
        XCTAssertEqual(vm.wordCount, 6)
        XCTAssertTrue(vm.includeUppercase)
        XCTAssertTrue(vm.includeLowercase)
        XCTAssertTrue(vm.includeDigits)
        XCTAssertTrue(vm.includeSymbols)
        XCTAssertFalse(vm.avoidAmbiguous)
        XCTAssertEqual(vm.separator, "-")
        XCTAssertFalse(vm.capitalize)
        XCTAssertFalse(vm.includeNumber)
    }

    // MARK: - fix-password-generator

    private func makeVM(generator: PasswordGenerator = PasswordGenerator()) -> PasswordGeneratorViewModel {
        PasswordGeneratorViewModel(provider: SeededRandomnessProvider(seed: 5), defaults: defaults,
                                   clipboard: ClipboardServiceImpl(pasteboard: FakePasteboard()),
                                   generator: generator)
    }

    func testNewSettingsDefaults() {
        let vm = makeVM()
        XCTAssertFalse(vm.includeExtendedSymbols)
        XCTAssertEqual(vm.minNumbers, 1)
        XCTAssertEqual(vm.minSpecial, 0)
    }

    func testMinimumsAboveTheLength_raiseTheShownAndStoredLength() {
        let vm = makeVM()
        vm.length = 5
        vm.minNumbers = 4
        vm.minSpecial = 4
        XCTAssertEqual(vm.length, 10, "4 + 4 + one uppercase + one lowercase")
        XCTAssertEqual(vm.generatedValue.count, 10)
        XCTAssertEqual(PasswordGeneratorConfig.load(from: defaults).length, 10)
    }

    func testLastEnabledSet_amongFive() {
        let vm = makeVM()
        vm.includeExtendedSymbols = true
        vm.includeUppercase = false
        vm.includeLowercase = false
        vm.includeDigits = false
        XCTAssertFalse(vm.isLastEnabledSet(.symbols), "special and extended: special is not the last")
        vm.includeSymbols = false
        XCTAssertTrue(vm.isLastEnabledSet(.extendedSymbols))
        XCTAssertFalse(vm.isLastEnabledSet(.symbols), "a disabled set is never locked")
        vm.includeSymbols = true
        vm.includeExtendedSymbols = false
        XCTAssertTrue(vm.isLastEnabledSet(.symbols))
    }

    func testMinimumSteppers_followTheirSets() {
        let vm = makeVM()
        XCTAssertTrue(vm.isMinSpecialEnabled)
        vm.includeSymbols = false
        XCTAssertFalse(vm.isMinSpecialEnabled)
        vm.includeDigits = false
        XCTAssertFalse(vm.isMinNumbersEnabled)
    }

    private struct FailingWordList: WordListSource {
        func words() throws -> [String] { throw PasswordGeneratorError.wordListUnavailable }
    }

    private struct FailingProvider: RandomnessProvider {
        struct Failure: Error {}
        func randomBytes(count: Int) throws -> [UInt8] { throw Failure() }
    }

    func testRandomSourceFailure_showsItsMessage_andOffersNothing() {
        let vm = PasswordGeneratorViewModel(provider: FailingProvider(), defaults: defaults,
                                            clipboard: ClipboardServiceImpl(pasteboard: FakePasteboard()))
        XCTAssertEqual(vm.errorMessage, "The system's random source failed. Nothing was generated.")
        XCTAssertEqual(vm.generatedValue, "")
        XCTAssertFalse(vm.canUse)
    }

    func testWordListFailure_showsItsMessage_andOffersNothing() {
        let vm = makeVM(generator: PasswordGenerator(wordListSource: FailingWordList()))
        vm.mode = .passphrase
        XCTAssertEqual(vm.errorMessage, "The word list for passphrases couldn't be loaded.")
        XCTAssertEqual(vm.generatedValue, "")
        XCTAssertFalse(vm.canUse)
    }

    /// Spec scenario "Toggle labels show their characters" (the UI test sees only the
    /// accessibility labels, which replace the visible text).
    func testToggleTitles_listTheirCharacters() {
        XCTAssertEqual(PasswordGeneratorView.specialToggleTitle, "Special (!@#$%^&*)")
        XCTAssertEqual(PasswordGeneratorView.extendedToggleTitle, #"Extended special (()_+-=[]{}|;':",.<>?/)"#)
    }

    // MARK: - generator-strength-meter

    func testStrength_followsTheSettings() {
        let vm = makeVM()
        XCTAssertEqual(vm.strength?.label, "Strong · 97 bits")
        vm.includeSymbols = false
        XCTAssertNotEqual(vm.strength?.label, "Strong · 97 bits", "a set off changes the strength")
        vm.includeSymbols = true
        vm.length = 8
        XCTAssertEqual(vm.strength?.category, .weak)
        vm.mode = .passphrase
        XCTAssertEqual(vm.strength?.label, "OK · 77 bits")
        vm.wordCount = 7
        XCTAssertEqual(vm.strength?.label, "Strong · 90 bits", "7 × log2(7,772) ≈ 90.4")
        let sevenWords = vm.strength?.label
        vm.includeNumber = true
        XCTAssertNotEqual(vm.strength?.label, sevenWords, "the number option changes the strength")
    }

    /// Spec scenario "Short password": the weak bar is red; strong is green.
    func testStrengthColor_weakIsRed_strongIsGreen() throws {
        let vm = makeVM()
        XCTAssertEqual(StrengthMeterView.color(for: try XCTUnwrap(vm.strength)), .green)
        vm.length = 8
        XCTAssertEqual(StrengthMeterView.color(for: try XCTUnwrap(vm.strength)), .red)
    }

    func testStrength_isHiddenOnError() {
        let vm = makeVM(generator: PasswordGenerator(wordListSource: FailingWordList()))
        vm.mode = .passphrase
        XCTAssertNil(vm.strength)
    }
}
