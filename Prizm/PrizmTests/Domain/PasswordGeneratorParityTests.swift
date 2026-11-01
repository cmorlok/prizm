import XCTest
@testable import Prizm

/// Uniform sampling, the two symbol sets, minimums, passphrase bounds and the visible word-list
/// failure (openspec change `fix-password-generator`).
@MainActor
final class PasswordGeneratorParityTests: XCTestCase {

    private let special = Set("!@#$%^&*")
    private let extended = Set("()_+-=[]{}|;':\",.<>?/")

    private struct FailingWordList: WordListSource {
        func words() throws -> [String] { throw PasswordGeneratorError.wordListUnavailable }
    }

    private struct FixedWordList: WordListSource {
        let list: [String]
        func words() throws -> [String] { list }
    }

    // MARK: - 1.2 Uniform index (design D1)

    func testRejectionBoundary() throws {
        let n = 7_772
        let limit = UInt32((UInt64(1) << 32) / UInt64(n) * UInt64(n) - 1)  // largest accepted
        let provider = ScriptedUInt32Provider([limit, limit + 1, UInt32.max, 5])
        XCTAssertEqual(try PasswordGenerator.uniformIndex(below: n, using: provider), Int(limit) % n)
        XCTAssertEqual(provider.drawn, 1)
        XCTAssertEqual(try PasswordGenerator.uniformIndex(below: n, using: provider), 5,
                       "limit and UInt32.max are rejected")
        XCTAssertEqual(provider.drawn, 4)
    }

    func testPowerOfTwo_acceptsEveryValue() throws {
        // 8 divides 2^32, so nothing is rejected (a UInt32-only limit would reject UInt32.max).
        let provider = ScriptedUInt32Provider([UInt32.max])
        XCTAssertEqual(try PasswordGenerator.uniformIndex(below: 8, using: provider), 7)
    }

    func testEndlessRejections_throw() {
        let provider = ScriptedUInt32Provider(Array(repeating: UInt32.max, count: 100))
        XCTAssertThrowsError(try PasswordGenerator.uniformIndex(below: 7_772, using: provider)) {
            XCTAssertEqual($0 as? PasswordGeneratorError, .randomSourceFailed)
        }
        XCTAssertEqual(provider.drawn, 64)
    }

    func testProviderErrorPropagates() {
        XCTAssertThrowsError(try PasswordGenerator.uniformIndex(below: 7, using: ScriptedUInt32Provider([])))
    }

    /// Chi-square goodness of fit over 100,000 draws; critical values at p = 0.001.
    func testUniformIndex_isUniform() throws {
        let critical: [Int: Double] = [7: 22.46, 8: 24.32, 62: 99.61, 70: 109.64, 7_772: 8_169.0]
        for (n, limit) in critical.sorted(by: { $0.key < $1.key }) {
            let provider = SeededRandomnessProvider(seed: 0xC0FFEE + UInt64(n))
            var counts = [Int](repeating: 0, count: n)
            let draws = 100_000
            for _ in 0..<draws { counts[try PasswordGenerator.uniformIndex(below: n, using: provider)] += 1 }
            let expected = Double(draws) / Double(n)
            let chi = counts.reduce(0.0) { $0 + pow(Double($1) - expected, 2) / expected }
            XCTAssertLessThan(chi, limit, "n = \(n)")
        }
    }

    // MARK: - 1.1 Word picks are uniform (fails with today's UInt16 % 7776)

    func testPassphraseWordPicks_areUniform() throws {
        let generator = PasswordGenerator()
        let list = try generator.wordList()
        let index = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1, $0) })
        var counts = [Int](repeating: 0, count: list.count)
        var config = PasswordGeneratorConfig()
        config.wordCount = 20
        config.separator = " "
        let provider = SeededRandomnessProvider(seed: 42)
        for _ in 0..<50_000 {
            for word in try generator.generatePassphrase(config: config, provider: provider, from: list)
                .split(separator: " ") {
                counts[index[String(word)]!] += 1
            }
        }
        let expected = 1_000_000.0 / Double(list.count)
        let chi = counts.reduce(0.0) { $0 + pow(Double($1) - expected, 2) / expected }
        XCTAssertLessThan(chi, 8_169.0, "chi-square over \(list.count) words")
    }

    // MARK: - 5.2 Character frequencies

    /// 10,000 default passwords (16 characters; upper, lower, digits, special): within each set
    /// every character is equally likely, and every position has the same mix of sets, so the
    /// shuffle places the required characters anywhere. Chi-square at p = 0.001, seeded provider.
    func testDefaultPasswords_frequenciesPerSetAndPosition() throws {
        let sets = [Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), Set("abcdefghijklmnopqrstuvwxyz"),
                    Set("0123456789"), special]
        let critical: [Double] = [52.62, 52.62, 27.88, 24.32]  // df 25, 25, 9, 7
        let provider = SeededRandomnessProvider(seed: 0x5EED)
        var charCounts: [Character: Int] = [:]
        var setPerPosition = [[Int]](repeating: [0, 0, 0, 0], count: 16)
        for _ in 0..<10_000 {
            let password = try PasswordGenerator().generatePassword(config: PasswordGeneratorConfig(), provider: provider)
            for (position, character) in password.enumerated() {
                charCounts[character, default: 0] += 1
                let set = try XCTUnwrap(sets.firstIndex { $0.contains(character) }, "\(character) is in no set")
                setPerPosition[position][set] += 1
            }
        }
        for (index, set) in sets.enumerated() {
            let counts = set.map { Double(charCounts[$0] ?? 0) }
            let expected = counts.reduce(0, +) / Double(counts.count)
            let chi = counts.reduce(0.0) { $0 + pow($1 - expected, 2) / expected }
            XCTAssertLessThan(chi, critical[index], "characters of set \(index)")
        }
        let totals = (0..<4).map { set in Double(setPerPosition.reduce(0) { $0 + $1[set] }) / 16 }
        for (position, counts) in setPerPosition.enumerated() {
            let chi = zip(counts, totals).reduce(0.0) { $0 + pow(Double($1.0) - $1.1, 2) / $1.1 }
            XCTAssertLessThan(chi, 16.27, "set mix at position \(position)")  // df 3
        }
    }

    func testWordList_withTheRightLengthButHyphenatedWords_isUnavailable() {
        let list = (0..<7_776).map { $0 < 10 ? "w-\($0)" : "w\($0)" }
        XCTAssertThrowsError(try PasswordGenerator(wordListSource: FixedWordList(list: list)).wordList()) {
            XCTAssertEqual($0 as? PasswordGeneratorError, .wordListUnavailable)
        }
    }

    // MARK: - 2.1 Sets

    func testDefaultPassword_usesSpecialButNotExtended() throws {
        let provider = SeededRandomnessProvider(seed: 7)
        let config = PasswordGeneratorConfig()
        XCTAssertEqual(config.length, 16)
        for _ in 0..<500 {
            let result = try PasswordGenerator().generatePassword(config: config, provider: provider)
            XCTAssertEqual(result.count, 16)
            XCTAssertTrue(result.contains(where: special.contains))
            XCTAssertFalse(result.contains(where: extended.contains), result)
            XCTAssertTrue(result.allSatisfy { $0.isLetter || $0.isNumber || special.contains($0) }, result)
        }
    }

    func testExtendedSet_contributes() throws {
        let provider = SeededRandomnessProvider(seed: 8)
        var config = PasswordGeneratorConfig()
        config.includeExtendedSymbols = true
        config.length = 5
        for _ in 0..<500 {
            let result = try PasswordGenerator().generatePassword(config: config, provider: provider)
            XCTAssertTrue(result.contains(where: extended.contains), result)
            XCTAssertFalse(result.contains(where: { $0.isWhitespace }))
        }
    }

    func testAvoidAmbiguous_removesExactlyTheseCharacters() throws {
        let provider = SeededRandomnessProvider(seed: 9)
        var config = PasswordGeneratorConfig()
        config.includeExtendedSymbols = true
        config.avoidAmbiguous = true
        config.length = 128
        var seen = Set<Character>()
        for _ in 0..<300 { seen.formUnion(try PasswordGenerator().generatePassword(config: config, provider: provider)) }
        XCTAssertTrue(seen.isDisjoint(with: Set("IOl01|")))
        XCTAssertTrue(seen.isSuperset(of: Set("Loi")), "only the listed letters go")
        XCTAssertTrue(seen.isSuperset(of: Set("23456789")))
    }

    // MARK: - 2.2 Minimums

    func testMinimums_areHonoured() throws {
        let provider = SeededRandomnessProvider(seed: 10)
        var config = PasswordGeneratorConfig()
        config.minNumbers = 3
        config.minSpecial = 2
        config.length = 8
        for _ in 0..<500 {
            let result = try PasswordGenerator().generatePassword(config: config, provider: provider)
            XCTAssertGreaterThanOrEqual(result.filter(\.isNumber).count, 3, result)
            XCTAssertGreaterThanOrEqual(result.filter(special.contains).count, 2, result)
        }
    }

    func testMinimumZero_stillGivesOneWhileTheSetIsOn() throws {
        let provider = SeededRandomnessProvider(seed: 11)
        var config = PasswordGeneratorConfig()
        config.minNumbers = 0
        config.minSpecial = 0
        config.length = 5
        for _ in 0..<500 {
            let result = try PasswordGenerator().generatePassword(config: config, provider: provider)
            XCTAssertTrue(result.contains(where: \.isNumber))
            XCTAssertTrue(result.contains(where: special.contains))
        }
    }

    func testMinimumsAboveTheLength_raiseTheLength() throws {
        var config = PasswordGeneratorConfig()
        config.length = 5
        config.minNumbers = 3
        config.minSpecial = 3
        XCTAssertEqual(config.effectiveLength, 8)
        let result = try PasswordGenerator().generatePassword(config: config, provider: SeededRandomnessProvider(seed: 12))
        XCTAssertEqual(result.count, 8)
    }

    // MARK: - 4.x Passphrase

    func testWordList_hasNoHyphenatedWords_and7772Entries() throws {
        let list = try PasswordGenerator().wordList()
        XCTAssertEqual(list.count, 7_772)
        XCTAssertFalse(list.contains { $0.contains("-") })
    }

    func testWordListOfTheWrongSize_throws() {
        let generator = PasswordGenerator(wordListSource: FixedWordList(list: ["one", "two", "three"]))
        XCTAssertThrowsError(try generator.wordList()) {
            XCTAssertEqual($0 as? PasswordGeneratorError, .wordListUnavailable)
        }
    }

    func testMissingWordList_throwsInsteadOfAnEmptyPassphrase() {
        let generator = PasswordGenerator(wordListSource: FailingWordList())
        XCTAssertThrowsError(try generator.generatePassphrase(config: PasswordGeneratorConfig(),
                                                              provider: SeededRandomnessProvider(seed: 1))) {
            XCTAssertEqual($0 as? PasswordGeneratorError, .wordListUnavailable)
        }
        XCTAssertEqual(PasswordGeneratorError.wordListUnavailable.errorDescription,
                       "The word list for passphrases couldn't be loaded.")
    }

    func testTwentyWords_andALongSeparator() throws {
        var config = PasswordGeneratorConfig()
        config.wordCount = 20
        config.separator = " :: "
        let result = try PasswordGenerator().generatePassphrase(config: config, provider: SeededRandomnessProvider(seed: 3))
        XCTAssertEqual(result.components(separatedBy: " :: ").count, 20)
        config.wordCount = 25
        let clamped = try PasswordGenerator().generatePassphrase(config: config, provider: SeededRandomnessProvider(seed: 3))
        XCTAssertEqual(clamped.components(separatedBy: " :: ").count, 20)
    }

    // MARK: - 2.3 Stored settings

    private func defaults() -> UserDefaults {
        let name = "PasswordGeneratorParityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaults() {
        let config = PasswordGeneratorConfig.load(from: defaults())
        XCTAssertEqual(config.length, 16)
        XCTAssertTrue(config.includeSymbols)
        XCTAssertFalse(config.includeExtendedSymbols)
        XCTAssertEqual(config.minNumbers, 1)
        XCTAssertEqual(config.minSpecial, 0)
    }

    func testStoredSymbolsWithOtherSets_keepExtendedOff() {
        let store = defaults()
        store.set(20, forKey: "pwgen.length")
        store.set(true, forKey: "pwgen.includeSymbols")
        let config = PasswordGeneratorConfig.load(from: store)
        XCTAssertEqual(config.length, 20)
        XCTAssertTrue(config.includeSymbols)
        XCTAssertFalse(config.includeExtendedSymbols)
    }

    func testStoredSymbolsOnly_turnsTheExtendedSetOnOnce() {
        let store = defaults()
        store.set(false, forKey: "pwgen.includeUppercase")
        store.set(false, forKey: "pwgen.includeLowercase")
        store.set(false, forKey: "pwgen.includeDigits")
        store.set(true, forKey: "pwgen.includeSymbols")
        XCTAssertTrue(PasswordGeneratorConfig.load(from: store).includeExtendedSymbols)

        store.set(false, forKey: "pwgen.includeExtendedSymbols")
        XCTAssertFalse(PasswordGeneratorConfig.load(from: store).includeExtendedSymbols,
                       "a stored choice wins")
    }

    func testStoredValuesAreClamped() {
        let store = defaults()
        store.set(40, forKey: "pwgen.minNumbers")
        store.set(-2, forKey: "pwgen.minSpecial")
        store.set(30, forKey: "pwgen.wordCount")
        let config = PasswordGeneratorConfig.load(from: store)
        XCTAssertEqual(config.minNumbers, 9)
        XCTAssertEqual(config.minSpecial, 0)
        XCTAssertEqual(config.wordCount, 20)
    }
}
