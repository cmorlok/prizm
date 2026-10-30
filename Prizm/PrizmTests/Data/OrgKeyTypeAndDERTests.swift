import XCTest
import Security
@testable import Prizm

/// fix-encstring-validation, tasks 3.1 and 4.1: organization keys are unwrapped from type 4 only,
/// and a malformed PKCS#8 private key fails with an error instead of crashing. A fresh RSA-2048 key
/// per test, wrapped as PKCS#8 here, so every malformed variant is exactly the one named.
final class OrgKeyTypeAndDERTests: XCTestCase {

    private let sut = PrizmCryptoServiceImpl()

    // MARK: - Fixtures

    private struct RSAKey {
        let pkcs1: Data
        let publicKey: SecKey
    }

    private func makeRSAKey() throws -> RSAKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeySizeInBits as String: 2048]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw try XCTUnwrap(error?.takeRetainedValue())
        }
        return RSAKey(pkcs1: pkcs1, publicKey: publicKey)
    }

    /// A DER length: short form below 128, otherwise long form with the fewest bytes.
    private func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var rest = length
        while rest > 0 { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    private static let rsaEncryptionOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])

    /// `SEQUENCE { INTEGER 0, SEQUENCE { OID, NULL }, OCTET STRING { pkcs1 } }` (RFC 5208 §5).
    private func pkcs8(_ pkcs1: Data, oid: Data = rsaEncryptionOID) -> Data {
        let algorithm = tlv(0x30, oid + Data([0x05, 0x00]))
        return tlv(0x30, tlv(0x02, Data([0x00])) + algorithm + tlv(0x04, pkcs1))
    }

    /// `bytes` wrapped for `key` as a type-4 EncString (RSA-OAEP-SHA1), as current clients write it.
    private func type4(_ bytes: Data, for key: RSAKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(key.publicKey, .rsaEncryptionOAEPSHA1, bytes as CFData, &error) as Data? else {
            throw try XCTUnwrap(error?.takeRetainedValue())
        }
        return "4." + wrapped.base64EncodedString()
    }

    private func assertUnwrap(_ encOrgKey: String, privateKey: Data, throws expected: PrizmCryptoServiceError,
                              _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await sut.unwrapOrgKey(encOrgKey: encOrgKey, rsaPrivateKey: privateKey)
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PrizmCryptoServiceError, expected, message, file: file, line: line)
        }
    }

    // MARK: - Task 3.1: org key types

    func testType4_unwrapsTheOrgKey() async throws {
        let key = try makeRSAKey()
        let orgKey = Data((0..<64).map { UInt8($0) })

        let unwrapped = try await sut.unwrapOrgKey(encOrgKey: try type4(orgKey, for: key), rsaPrivateKey: pkcs8(key.pkcs1))

        XCTAssertEqual(unwrapped.toData(), orgKey)
    }

    /// An empty private key would fail as malformed if any RSA work came first, so these errors also
    /// show that the type is checked before the key is touched.
    func testTypes3_5_6_areUnsupported_beforeAnyRSAWork() async {
        let blob = Data(repeating: 0x42, count: 256).base64EncodedString()
        let mac = Data(repeating: 0x43, count: 32).base64EncodedString()
        await assertUnwrap("3.\(blob)", privateKey: Data(), throws: .unsupportedOrgKeyType(3))
        await assertUnwrap("5.\(blob)|\(mac)", privateKey: Data(), throws: .unsupportedOrgKeyType(5))
        await assertUnwrap("6.\(blob)|\(mac)", privateKey: Data(), throws: .unsupportedOrgKeyType(6))
    }

    func testOtherForms_areMalformed() async {
        let blob = Data(repeating: 0x42, count: 256).base64EncodedString()
        await assertUnwrap("4.\(blob)|\(blob)", privateKey: Data(), throws: .malformedOrgKey)
        await assertUnwrap("2.\(blob)|\(blob)|\(blob)", privateKey: Data(), throws: .malformedOrgKey)
        await assertUnwrap("7.\(blob)", privateKey: Data(), throws: .malformedOrgKey)
        await assertUnwrap("4.not base64!", privateKey: Data(), throws: .malformedOrgKey)
        await assertUnwrap("4.", privateKey: Data(), throws: .malformedOrgKey)
        await assertUnwrap(blob, privateKey: Data(), throws: .malformedOrgKey)
    }

    /// Code review 2026-10-30: an org key for another member's RSA key is its own error, not
    /// `invalidEncUserKey` (the user key is fine).
    func testOrgKeyForAnotherKey_isOrgKeyUnwrapFailed() async throws {
        let mine = try makeRSAKey()
        let theirs = try makeRSAKey()
        await assertUnwrap(try type4(Data(repeating: 7, count: 64), for: theirs), privateKey: pkcs8(mine.pkcs1),
                           throws: .orgKeyUnwrapFailed)
    }

    func testTypePrefix_isTheLiteralDigit() async {
        let blob = Data(repeating: 0x42, count: 256).base64EncodedString()
        await assertUnwrap("+4.\(blob)", privateKey: Data(), throws: .malformedOrgKey)
        await assertUnwrap("04.\(blob)", privateKey: Data(), throws: .malformedOrgKey)
    }

    func testA32ByteOrgKey_isRefused() async throws {
        let key = try makeRSAKey()
        await assertUnwrap(try type4(Data(repeating: 7, count: 32), for: key), privateKey: pkcs8(key.pkcs1),
                     throws: .invalidSymmetricKeyLength)
    }

    func testUnsupportedOrgKeyType_logDescriptionNamesTheTypeOnly() {
        XCTAssertEqual(ErrorLog.describe(PrizmCryptoServiceError.unsupportedOrgKeyType(5)),
                       "PrizmCryptoServiceError.unsupportedOrgKeyType(5)")
    }

    // MARK: - Task 4.1: DER bounds

    func testMalformedPrivateKeys_failWithoutACrash() async throws {
        let key = try makeRSAKey()
        let encOrgKey = try type4(Data(repeating: 1, count: 64), for: key)
        let good = pkcs8(key.pkcs1)
        let algorithm = tlv(0x30, Self.rsaEncryptionOID + Data([0x05, 0x00]))
        let inner = tlv(0x02, Data([0x00])) + algorithm + tlv(0x04, key.pkcs1)

        var cases: [(String, Data)] = [
            ("truncated", good.prefix(good.count - 10)),
            ("only the outer header", good.prefix(4)),
            ("outer length larger than the buffer", Data([0x30, 0x84, 0x7F, 0xFF, 0xFF, 0xFF]) + inner),
            ("five-byte length", Data([0x30, 0x85, 0x00, 0x00, 0x00, 0x00, UInt8(inner.count & 0xFF)]) + inner),
            ("indefinite length", Data([0x30, 0x80]) + inner + Data([0x00, 0x00])),
            ("wrong algorithm", pkcs8(key.pkcs1, oid: Data([0x06, 0x03, 0x2B, 0x65, 0x70]))),
            ("empty", Data()),
        ]
        // The OCTET STRING runs past the outer SEQUENCE: the outer length leaves out its last 8 bytes.
        let short = Data([0x30]) + derLength(inner.count - 8) + inner
        cases.append(("octet string past the outer sequence", short))
        // The version INTEGER claims more bytes than the outer SEQUENCE holds.
        cases.append(("version length past the end", tlv(0x30, Data([0x02, 0x7F, 0x00]))))

        for (name, privateKey) in cases {
            await assertUnwrap(encOrgKey, privateKey: privateKey, throws: .malformedPrivateKey, name)
        }
        let unwrapped = try await sut.unwrapOrgKey(encOrgKey: encOrgKey, rsaPrivateKey: good)
        XCTAssertEqual(unwrapped.toData(), Data(repeating: 1, count: 64), "the well-formed key")
    }
}
