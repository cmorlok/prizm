import XCTest
@testable import Prizm

/// fix-encstring-validation: which EncStrings Prizm decrypts and how strictly it parses them
/// (design.md D1–D3). Vectors are built from a real type-2 encryption, so the type-0 case is the
/// MAC-stripping attack itself: same IV and ciphertext, MAC removed.
final class EncStringValidationTests: XCTestCase {

    private let keys = CryptoKeys(encryptionKey: Data(repeating: 0xDE, count: 32),
                                  macKey: Data(repeating: 0xAD, count: 32))

    private func b64(_ byteCount: Int, _ byte: UInt8 = 0x11) -> String {
        Data(repeating: byte, count: byteCount).base64EncodedString()
    }

    private func type2(iv: Int = 16, ct: Int = 32, mac: Int = 32) -> String {
        "2.\(b64(iv))|\(b64(ct, 0x22))|\(b64(mac, 0x33))"
    }

    private func assertParse(_ string: String, throws expected: EncStringError,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EncString(string: string), file: file, line: line) { error in
            XCTAssertEqual(error as? EncStringError, expected, file: file, line: line)
        }
    }

    // MARK: - Task 1.1: type 0 is never decrypted

    func testType0_withTheRightKey_isNeverDecrypted() throws {
        let genuine = try EncString.encrypt(data: Data("secret".utf8), keys: keys)
        let stripped = "0.\(genuine.iv.base64EncodedString())|\(genuine.ciphertext.base64EncodedString())"

        let enc = try EncString(string: stripped)   // parsing still works (D3)
        XCTAssertThrowsError(try enc.decrypt(keys: keys)) { error in
            XCTAssertEqual(error as? EncStringError, .unsupportedEncType)
        }
    }

    // MARK: - Task 1.2: RSA and COSE types are not symmetric

    func testRSATypes_andCOSE_areRefusedAtParse() {
        assertParse("3.\(b64(256))", throws: .unsupportedEncType)
        assertParse("4.\(b64(16))|\(b64(32))|\(b64(32))", throws: .unsupportedEncType)
        assertParse("5.\(b64(256))|\(b64(32))", throws: .unsupportedEncType)
        assertParse("6.\(b64(256))", throws: .unsupportedEncType)
        assertParse("7.\(b64(64))", throws: .unsupportedEncType)
    }

    /// Code review 2026-10-30: the type is the literal digit, as in the SDK; `Int(_:)` also took a
    /// sign or leading zeros.
    func testTypePrefix_isTheLiteralDigit() {
        let body = String(type2().dropFirst(2))
        for prefix in ["+2", "02", "002", "-2", " 2", "2 ", "２"] {
            assertParse("\(prefix).\(body)", throws: .malformedEncString)
        }
        XCTAssertNoThrow(try EncString(string: "2.\(body)"))
    }

    // MARK: - Task 1.3: strict lengths, one error per case

    func testIVOfTheWrongLength_isInvalidIVLength() {
        for length in [0, 8, 17] {
            assertParse(type2(iv: length), throws: .invalidIVLength)
        }
        assertParse("0.\(b64(8))|\(b64(32))", throws: .invalidIVLength)
    }

    func testMalformedType2_isMalformed() {
        assertParse(type2(mac: 31), throws: .malformedEncString)
        assertParse(type2(mac: 33), throws: .malformedEncString)
        assertParse(type2(ct: 0), throws: .malformedEncString)
        assertParse(type2(ct: 15), throws: .malformedEncString)
        assertParse("2.\(b64(16))|\(b64(32))", throws: .malformedEncString)
        assertParse("2.\(b64(16))|not base64!|\(b64(32))", throws: .malformedEncString)
        assertParse("2.\(b64(16))|\(b64(32))|\(b64(32))|\(b64(32))", throws: .malformedEncString)
    }

    func testWellFormedType2_stillParsesAndDecrypts() throws {
        let genuine = try EncString.encrypt(data: Data("secret".utf8), keys: keys)
        let parsed = try EncString(string: genuine.toString())
        XCTAssertEqual(try parsed.decrypt(keys: keys), Data("secret".utf8))
    }

    // MARK: - D3: the AES helpers refuse wrong lengths instead of reading past a buffer

    func testAESHelpers_refuseAShortIVOrKey() {
        let ct = Data(repeating: 0x22, count: 32)
        XCTAssertThrowsError(try EncString.aesCbcDecrypt(key: Data(count: 32), iv: Data(count: 8), ciphertext: ct)) {
            XCTAssertEqual($0 as? EncStringError, .invalidIVLength)
        }
        XCTAssertThrowsError(try EncString.aesCbcDecrypt(key: Data(count: 16), iv: Data(count: 16), ciphertext: ct)) {
            XCTAssertEqual($0 as? EncStringError, .decryptionFailed)
        }
        XCTAssertThrowsError(try EncString.aesCbcEncrypt(key: Data(count: 32), iv: Data(), plaintext: ct)) {
            XCTAssertEqual($0 as? EncStringError, .invalidIVLength)
        }
    }
}
