import XCTest
@testable import Prizm

/// Entropy and category of the generator's settings (openspec change `generator-strength-meter`).
@MainActor
final class GeneratorStrengthTests: XCTestCase {

    private let words = 7_772

    private func strength(_ edit: (inout PasswordGeneratorConfig) -> Void) -> GeneratorStrength {
        var config = PasswordGeneratorConfig()
        edit(&config)
        return GeneratorStrength.of(config, wordListSize: words)
    }

    // Expected bits: log2 of the number of passwords the settings allow, counted exactly with big
    // integers outside the app (sum over the set counts of multinomial × size^count).

    func testDefaultPassword_isStrong97() {
        let s = strength { _ in }
        XCTAssertEqual(s.bits, 97.7085, accuracy: 1e-3, "16 characters, one or more of each of four sets")
        XCTAssertEqual(s.category, .strong)
        XCTAssertEqual(s.label, "Strong · 97 bits")
    }

    func testHighMinimums_countOnlyWhatTheSettingsAllow() {
        let s = strength { $0.length = 12; $0.minNumbers = 9 }
        XCTAssertEqual(s.bits, 52.6646, accuracy: 1e-3, "12 × log2(70) would claim 73.6")
        XCTAssertEqual(s.category, .weak)
        let both = strength { $0.length = 20; $0.minNumbers = 9; $0.minSpecial = 9 }
        XCTAssertEqual(both.bits, 90.4374, accuracy: 1e-3)
    }

    func testShortPassword_isWeak() {
        let s = strength { $0.length = 8 }
        XCTAssertEqual(s.label, "Weak · 47 bits")
        XCTAssertEqual(s.category, .weak)
    }

    func testSixWords_isOK77() {
        let s = strength { $0.mode = .passphrase }
        XCTAssertEqual(s.label, "OK · 77 bits")
    }

    func testSixWordsWithANumber_addsDigitAndPosition() {
        let s = strength { $0.mode = .passphrase; $0.includeNumber = true }
        XCTAssertEqual(s.bits, 6 * log2(7_772) + log2(10) + log2(6), accuracy: 1e-9)
        XCTAssertEqual(s.category, .strong)
    }

    func testEverySet_24_isVeryStrong() {
        let s = strength { $0.length = 24; $0.includeExtendedSymbols = true }
        XCTAssertEqual(s.label, "Very strong · 155 bits")
        XCTAssertEqual(s.fill, 1)
    }

    func testAvoidAmbiguous_shrinksThePool() {
        let s = strength { $0.avoidAmbiguous = true }
        XCTAssertEqual(s.bits, 95.972, accuracy: 1e-3, "sets of 24, 25, 8 and 8: I, O, l, 0, 1 removed")
    }

    func testMinimumsAboveTheLength_useTheEffectiveLength() {
        let s = strength { $0.length = 5; $0.minNumbers = 9; $0.minSpecial = 9 }
        XCTAssertEqual(s.bits, 90.4374, accuracy: 1e-3, "the same as length 20")
    }

    func testThresholds() {
        XCTAssertEqual(GeneratorStrength.Category(bits: 63.99), .weak)
        XCTAssertEqual(GeneratorStrength.Category(bits: 64), .ok)
        XCTAssertEqual(GeneratorStrength.Category(bits: 79.99), .ok)
        XCTAssertEqual(GeneratorStrength.Category(bits: 80), .strong)
        XCTAssertEqual(GeneratorStrength.Category(bits: 127.99), .strong)
        XCTAssertEqual(GeneratorStrength.Category(bits: 128), .veryStrong)
    }

    func testAccessibilityValue() {
        XCTAssertEqual(strength { _ in }.accessibilityValue, "Strong, 97 bits")
    }
}
