import XCTest
@testable import Prizm

/// Ed25519 generation, OpenSSH import and fingerprints (openspec change
/// `ssh-key-import-and-generation`, design D3–D5). Known answers come from `ssh-keygen`
/// (`Fixtures/ssh-key-vectors.json`, see the fixtures README), never from the Bitwarden SDK (D8).
final class SSHKeyServiceTests: XCTestCase {

    private let sut = SSHKeyServiceImpl()

    private struct Vectors: Decodable {
        struct Accepted: Decodable { let name, privateKey, publicKey, fingerprint: String }
        struct Refused: Decodable { let name, privateKey, error: String }
        let accepted: [Accepted]
        let refused: [Refused]
    }

    private func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data(named: "ssh-key-vectors"))
    }

    /// The refusal for a vector; the type and format refusals name what was found (spec: "name the
    /// unsupported type or format").
    private func error(named name: String, vector: String = "") -> SSHKeyError? {
        let formats: [String: SSHKeyFormat] = ["pem-rsa": .pem, "pkcs8-ecdsa": .pkcs8, "putty": .putty,
                                               "two-keys": .multipleKeys]
        let types = ["rsa": "RSA", "rsa-passphrase-protected": "RSA", "ecdsa": "ECDSA"]
        switch name {
        case "notOpenSSHKey":       return .notOpenSSHKey
        case "passphraseProtected": return .passphraseProtected
        case "unsupportedFormat":   return .unsupportedFormat(formats[vector] ?? .other)
        case "unsupportedKeyType":  return .unsupportedKeyType(types[vector])
        case "securityKey":         return .securityKey
        case "damaged":             return .damaged
        case "inconsistent":        return .inconsistent
        default:                    return nil
        }
    }

    /// The armour `ssh-keygen` writes: 70 columns, trailing newline.
    private func armour(_ bytes: [UInt8]) -> String {
        let base64 = Data(bytes).base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            return String(base64[start..<(base64.index(start, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex)])
        }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"])
            .joined(separator: "\n") + "\n"
    }

    private func decoded(_ privateKey: String) throws -> [UInt8] {
        let base64 = privateKey.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return [UInt8](try XCTUnwrap(Data(base64Encoded: base64)))
    }

    // MARK: - Fingerprint (task 1.2)

    func testFingerprint_matchesSSHKeygen() throws {
        for vector in try vectors().accepted {
            XCTAssertEqual(sut.fingerprint(forPublicKey: vector.publicKey), vector.fingerprint, vector.name)
            XCTAssertEqual(sut.fingerprint(forPublicKey: vector.publicKey + " user@host"), vector.fingerprint,
                           "\(vector.name): a trailing comment is allowed")
        }
    }

    func testFingerprint_nilForTextThatIsNotAPublicKey() throws {
        let blob = try XCTUnwrap(try vectors().accepted.first?.publicKey.split(separator: " ").last)
        XCTAssertNil(sut.fingerprint(forPublicKey: ""))
        XCTAssertNil(sut.fingerprint(forPublicKey: "ssh-ed25519"))
        XCTAssertNil(sut.fingerprint(forPublicKey: "ssh-ed25519 !!!not-base64"))
        XCTAssertNil(sut.fingerprint(forPublicKey: "ssh-rsa \(blob)"), "the blob names another type")
    }

    // MARK: - Import (tasks 3.1, 3.4)

    func testParse_acceptedVectors() throws {
        let vectors = try vectors()
        let originals = Dictionary(uniqueKeysWithValues: vectors.accepted.prefix(3).map { ($0.name, $0.privateKey) })
        for vector in vectors.accepted {
            let material = try sut.parse(privateKeyText: vector.privateKey)
            XCTAssertEqual(material.publicKey, vector.publicKey, vector.name)
            XCTAssertEqual(material.fingerprint, vector.fingerprint, vector.name)
            // Stored as a new armour of the checked bytes: what ssh-keygen wrote (design D4).
            let original = originals[String(vector.name.prefix(3))]
            XCTAssertEqual(material.privateKey, original, "\(vector.name): stored text is ssh-keygen's armour")
        }
    }

    func testParse_refusedVectors() throws {
        for vector in try vectors().refused {
            let expected = try XCTUnwrap(error(named: vector.error, vector: vector.name), "unknown error name in \(vector.name)")
            XCTAssertThrowsError(try sut.parse(privateKeyText: vector.privateKey), vector.name) { error in
                XCTAssertEqual(error as? SSHKeyError, expected, vector.name)
            }
        }
    }

    // MARK: - Truncation (task 3.2)

    func testParse_cutAtEveryByte_isRefusedWithoutCrashing() throws {
        let bytes = try decoded(try XCTUnwrap(try vectors().accepted.first).privateKey)
        for length in 0..<bytes.count {
            let text = armour(Array(bytes.prefix(length)))
            XCTAssertThrowsError(try sut.parse(privateKeyText: text), "cut at \(length)") { error in
                let refusal = error as? SSHKeyError
                XCTAssertNotNil(refusal, "cut at \(length)")
                if length > 0 { XCTAssertEqual(refusal, .damaged, "cut at \(length)") }
            }
        }
    }

    func testRefusals_nameTheTypeOrFormat() {
        XCTAssertTrue(SSHKeyError.unsupportedKeyType("RSA").userMessage.contains("RSA"))
        XCTAssertTrue(SSHKeyError.unsupportedFormat(.pem).userMessage.contains("PEM"))
        XCTAssertTrue(SSHKeyError.unsupportedFormat(.pkcs8).userMessage.contains("PKCS#8"))
        XCTAssertTrue(SSHKeyError.unsupportedFormat(.putty).userMessage.contains("PuTTY"))
        XCTAssertTrue(SSHKeyError.unsupportedFormat(.multipleKeys).userMessage.contains("more than one key"))
    }

    func testParse_inputAbove16KiB_isRefused() {
        let text = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + String(repeating: "A", count: 16 * 1024) + "\n-----END OPENSSH PRIVATE KEY-----\n"
        XCTAssertThrowsError(try sut.parse(privateKeyText: text)) { XCTAssertEqual($0 as? SSHKeyError, .notOpenSSHKey) }
    }

    // MARK: - Generation (tasks 2.1, 2.2)

    func testGenerate_returnsAMatchingTriple() throws {
        let material = try sut.generate()
        XCTAssertTrue(material.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(material.privateKey.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        XCTAssertTrue(material.privateKey.split(separator: "\n").allSatisfy { $0.count <= 70 })
        XCTAssertTrue(material.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertEqual(material.fingerprint, sut.fingerprint(forPublicKey: material.publicKey))
        XCTAssertTrue(material.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(material.fingerprint.hasSuffix("="))
    }

    func testGenerate_passesTheImporter() throws {
        let generated = try sut.generate()
        XCTAssertEqual(try sut.parse(privateKeyText: generated.privateKey), generated)
    }

    func testGenerate_twoCallsDiffer() throws {
        XCTAssertNotEqual(try sut.generate().publicKey, try sut.generate().publicKey)
    }

    // MARK: - Secrets (tasks 1.3, 3.4)

    func testDescriptionsHoldNoKeyText() throws {
        let material = try sut.generate()
        for text in [String(describing: material), String(reflecting: material), "\(material)"] {
            XCTAssertFalse(text.contains(material.privateKey.split(separator: "\n")[1]), text)
            XCTAssertFalse(text.contains(material.publicKey), text)
        }
    }

    func testErrorMessagesHoldNoKeyText() throws {
        for vector in try vectors().refused {
            guard let error = error(named: vector.error, vector: vector.name) else { continue }
            let firstLine = vector.privateKey.split(separator: "\n").dropFirst().first.map(String.init) ?? vector.privateKey
            XCTAssertFalse(error.userMessage.contains(firstLine), vector.name)
            XCTAssertFalse(String(describing: error).contains(firstLine), vector.name)
        }
    }
}
