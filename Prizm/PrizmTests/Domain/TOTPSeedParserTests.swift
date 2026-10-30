import XCTest
@testable import Prizm

/// Parser table from specs/001-totp-verification-codes/contracts/domain-protocols.md.
final class TOTPSeedParserTests: XCTestCase {

    // "JBSWY3DPEHPK3PXP" is base32 for the ASCII bytes "Hello!\u{DE}\u{AD}\u{BE}\u{EF}".
    private let secretBase32 = "JBSWY3DPEHPK3PXP"
    private var secretBytes: Data { Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0xDE, 0xAD, 0xBE, 0xEF]) }

    func test_plainBase32_withSpacesAndLowercase_usesDefaults() throws {
        let config = try TOTPSeedParser.parse("jbsw y3dp ehpk 3pxp")
        XCTAssertEqual(config.secret, secretBytes)
        XCTAssertEqual(config.algorithm, .sha1)
        XCTAssertEqual(config.digits, 6)
        XCTAssertEqual(config.period, 30)
    }

    func test_plainBase32_withPadding_isAccepted() throws {
        // 8 base32 chars = 5 bytes; "MFRGG===" is "abc" padded.
        let config = try TOTPSeedParser.parse("MFRGG===")
        XCTAssertEqual(config.secret, Data("abc".utf8))
    }

    func test_otpauth_withAllParameters() throws {
        let uri = "otpauth://totp/Acme:me?secret=\(secretBase32)&digits=8&period=60&algorithm=SHA256"
        let config = try TOTPSeedParser.parse(uri)
        XCTAssertEqual(config.secret, secretBytes)
        XCTAssertEqual(config.algorithm, .sha256)
        XCTAssertEqual(config.digits, 8)
        XCTAssertEqual(config.period, 60)
    }

    func test_otpauth_sha512_andLowercaseAlgorithm() throws {
        let config = try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)&algorithm=sha512")
        XCTAssertEqual(config.algorithm, .sha512)
    }

    func test_otpauth_withDefaults() throws {
        let config = try TOTPSeedParser.parse("otpauth://totp/Acme:me?secret=\(secretBase32)&issuer=Acme")
        XCTAssertEqual(config.algorithm, .sha1)
        XCTAssertEqual(config.digits, 6)
        XCTAssertEqual(config.period, 30)
    }

    func test_emptyAndWhitespace_throwEmptySeed() {
        XCTAssertThrowsError(try TOTPSeedParser.parse("")) { XCTAssertEqual($0 as? TOTPError, .emptySeed) }
        XCTAssertThrowsError(try TOTPSeedParser.parse("  \n\t ")) { XCTAssertEqual($0 as? TOTPError, .emptySeed) }
    }

    // MARK: - Lenient rules, as the Bitwarden SDK (totp-parity, design D1)

    func test_nonBase32Characters_areIgnored() throws {
        XCTAssertEqual(try TOTPSeedParser.parse("JBSW-Y3DP-EHPK-3PXP").secret, secretBytes)
        // "not-a-seed!" keeps NOTASEED: 40 bits, 5 bytes, a usable key as in official apps.
        XCTAssertEqual(try TOTPSeedParser.parse("not-a-seed!").secret.count, 5)
        // The SDK iterates Unicode scalars: a combining accent is dropped, the base letter kept.
        XCTAssertEqual(try TOTPSeedParser.parse("JBSWY3DPE\u{0301}HPK3PXP").secret, secretBytes)
    }

    func test_otherSchemes_arePlainSecrets() throws {
        // "https://example.com" keeps HTTPSEXAMPLECOM (15 letters, 75 bits → 9 bytes).
        let config = try TOTPSeedParser.parse("https://example.com")
        XCTAssertEqual(config.secret, Data([60, 230, 249, 18, 224, 99, 214, 65, 57]))
        XCTAssertEqual(config.digits, 6)
    }

    func test_dottedCapitalI_lowercasesToIAndACombiningDot() throws {
        // The seed is lowercased first, as in the SDK: U+0130 becomes "i" + U+0307. The "i" is a
        // base32 letter and counts; the combining dot is outside the alphabet and is dropped.
        XCTAssertEqual(try TOTPSeedParser.parse("JBSWY3DP\u{0130}EHPK3PXP").secret,
                       try TOTPSeedParser.parse("JBSWY3DPIEHPK3PXP").secret)
    }

    func test_percentEscapes_areDecodedOneByOne_asWHATWGFormDecoding() throws {
        // A valid escape is decoded, an invalid one kept as written ("%" alone is then dropped as
        // a non-alphabet character), and invalid UTF-8 becomes U+FFFD, which is dropped too.
        XCTAssertEqual(try TOTPSeedParser.parse("otpauth://totp/x?secret=%4aBSWY3DPEHPK3PXP%").secret, secretBytes)
        XCTAssertEqual(try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)%FF").secret, secretBytes)
    }

    func test_algorithm_matchesWithoutCase_afterDecoding() throws {
        XCTAssertEqual(try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)&algorithm=%53HA256").algorithm, .sha256)
    }

    func test_hotpHost_isFoundBehindUserinfoAndPort() {
        for uri in ["otpauth://u@hotp/x?secret=\(secretBase32)", "otpauth://hotp:1/x?secret=\(secretBase32)"] {
            XCTAssertThrowsError(try TOTPSeedParser.parse(uri), uri) {
                XCTAssertEqual($0 as? TOTPError, .unsupportedScheme)
            }
        }
    }

    /// Task 4.1: codes are never gated on premium or an organization's TOTP flag (design D5). The
    /// sync model decodes no such field, so nothing can gate them.
    func test_syncModel_decodesNoEntitlementField() throws {
        // …/Prizm/PrizmTests/Domain/TOTPSeedParserTests.swift → …/Prizm
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = appRoot.appendingPathComponent("Data/Network/Models/SyncResponse.swift")
        let source = try String(contentsOf: model, encoding: .utf8)
        XCTAssertFalse(source.localizedCaseInsensitiveContains("premium"))
        XCTAssertFalse(source.contains("organizationUseTotp"))
        XCTAssertFalse(source.contains("useTotp"))
    }

    func test_otpauth_anyHostButHotp_isTotp() throws {
        for host in ["totp", "TOTP", "", "other"] {
            let config = try TOTPSeedParser.parse("otpauth://\(host)/x?secret=\(secretBase32)")
            XCTAssertEqual(config.secret, secretBytes, host)
        }
        XCTAssertEqual(try TOTPSeedParser.parse("OTPauth://totp/x?secret=\(secretBase32)").secret, secretBytes)
    }

    func test_otpauth_labelWithSpace_andRepeatedSecret_lastWins() throws {
        let config = try TOTPSeedParser.parse("otpauth://totp/ACME Co:me?secret=AAAAAAAA&secret=\(secretBase32)")
        XCTAssertEqual(config.secret, secretBytes)
    }

    func test_otpauth_formEncodedValues() throws {
        // `+` is a space and `%2D` a dash; both are dropped from the secret.
        XCTAssertEqual(try TOTPSeedParser.parse("otpauth://totp/x?secret=JBSW+Y3DP%2DEHPK3PXP").secret, secretBytes)
    }

    func test_unknownAlgorithm_isSha1_andDigitsClampAtTen() throws {
        let config = try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)&algorithm=MD5&digits=9")
        XCTAssertEqual(config.algorithm, .sha1)
        XCTAssertEqual(config.digits, 9)
        XCTAssertEqual(try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)&digits=11").digits, 10)
        XCTAssertEqual(try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)&digits=5").digits, 5)
        XCTAssertEqual(try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)&digits=1").digits, 1)
    }

    func test_integers_followRustU32Parsing() throws {
        func parse(_ query: String) throws -> TOTPConfiguration {
            try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)&\(query)")
        }
        XCTAssertEqual(try parse("digits=-1").digits, 6, "negative: not a u32, default")
        XCTAssertEqual(try parse("digits=99999999999").digits, 6, "above u32: default")
        XCTAssertEqual(try parse("digits=abc").digits, 6)
        XCTAssertEqual(try parse("digits=%2B8").digits, 8, "a leading + is accepted")
        XCTAssertEqual(try parse("digits=+8").digits, 6, "an unescaped + is a space in a query, as in the SDK")
        XCTAssertEqual(try parse("period=-30").period, 30)
        XCTAssertEqual(try parse("period=abc").period, 30)
        XCTAssertEqual(try parse("period=0").period, 1, "at least 1")
        XCTAssertEqual(try parse("period=60").period, 60)
    }

    func test_steam_isFiveCharactersOfThirtySeconds() throws {
        let config = try TOTPSeedParser.parse("steam://\(secretBase32)")
        XCTAssertEqual(config.secret, secretBytes)
        XCTAssertEqual(config.alphabet, .steam)
        XCTAssertEqual(config.digits, 5)
        XCTAssertEqual(config.period, 30)
        XCTAssertEqual(config.algorithm, .sha1)
        XCTAssertEqual(try TOTPSeedParser.parse("STEAM://\(secretBase32)").alphabet, .steam)
    }

    func test_surroundingWhitespace_isTrimmed() throws {
        // A recorded difference from the SDK (design D2), which would read the URI's letters.
        XCTAssertEqual(try TOTPSeedParser.parse("  otpauth://totp/x?secret=\(secretBase32)&digits=8 \n").digits, 8)
    }

    // MARK: - Recorded exceptions: never a valid code (design D2)

    func test_hotp_isUnsupported() {
        XCTAssertThrowsError(try TOTPSeedParser.parse("otpauth://hotp/Acme:me?secret=\(secretBase32)&counter=1")) {
            XCTAssertEqual($0 as? TOTPError, .unsupportedScheme)
        }
    }

    func test_zeroByteSecrets_areInvalid() {
        for seed in ["A", "1890", "!!!", "steam://", "otpauth://totp/x?secret=A"] {
            XCTAssertThrowsError(try TOTPSeedParser.parse(seed), seed) { XCTAssertEqual($0 as? TOTPError, .invalidSecret, seed) }
        }
    }

    func test_otpauth_missingSecret_throwsInvalidSecret() {
        XCTAssertThrowsError(try TOTPSeedParser.parse("otpauth://totp/Acme:me?issuer=Acme")) {
            XCTAssertEqual($0 as? TOTPError, .invalidSecret)
        }
        XCTAssertThrowsError(try TOTPSeedParser.parse("otpauth://totp/Acme:me?secret=")) {
            XCTAssertEqual($0 as? TOTPError, .invalidSecret)
        }
    }

    func test_zeroDigits_isUnsupported() {
        XCTAssertThrowsError(try TOTPSeedParser.parse("otpauth://totp/x?secret=\(secretBase32)&digits=0")) {
            XCTAssertEqual($0 as? TOTPError, .unsupportedParameter)
        }
    }

    /// The seed must never appear in an error description (Constitution §III, §V).
    func test_errorDescription_doesNotContainSeed() {
        let seed = "otpauth://totp/x?secret=\(secretBase32)&digits=0"
        XCTAssertThrowsError(try TOTPSeedParser.parse(seed)) { error in
            XCTAssertFalse("\(error)".contains(secretBase32))
            XCTAssertFalse(String(reflecting: error).contains(secretBase32))
        }
    }
}
