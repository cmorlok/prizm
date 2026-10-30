import XCTest
@testable import Prizm

/// SSH key items keep private key, public key and fingerprint together on every write, and an
/// incomplete one is not edited (openspec change `fix-ssh-key-roundtrip`). Real crypto throughout.
@MainActor
final class SSHKeyIntegrityTests: XCTestCase {

    private let mapper = CipherMapper()
    private let keys = KeyedCipherBuilder.randomKeys()

    private let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE=\n-----END OPENSSH PRIVATE KEY-----"
    private let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample user@host"
    private let fingerprint = "SHA256:ZXhhbXBsZWZpbmdlcnByaW50"

    // MARK: - Fixture

    private func enc(_ plaintext: String) -> String {
        KeyedCipherBuilder.encrypt(plaintext, keys: keys)
    }

    private func dec(_ encString: String?, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let string = try XCTUnwrap(encString, "not an EncString", file: file, line: line)
        return try XCTUnwrap(String(data: try EncString(string: string).decrypt(keys: keys), encoding: .utf8))
    }

    /// A type 5 record as a server sends it; `sshKey` nil leaves the member out, NSNull sends null.
    private func record(sshKey: Any?) throws -> RawCipher {
        var json: [String: Any] = [
            "id": "ssh-1",
            "type": 5,
            "name": enc("Deploy key"),
            "notes": enc("old notes"),
            "favorite": false,
            "reprompt": 0,
            "revisionDate": RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
            "creationDate": RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
        ]
        if let sshKey { json["sshKey"] = sshKey }
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func completeRecord() throws -> RawCipher {
        try record(sshKey: ["privateKey": enc(privateKey), "publicKey": enc(publicKey),
                            "keyFingerprint": enc(fingerprint)])
    }

    // MARK: - Edit keeps the key (tasks 2.1, 2.2)

    func testEdit_sendsStoredFingerprintAndUnchangedKeys() throws {
        let stored = try completeRecord()
        var draft = DraftVaultItem(try mapper.map(raw: stored, vaultKeys: keys).item)
        draft.name = "Renamed"
        guard case .sshKey(var ssh) = draft.content else { return XCTFail("not an SSH key") }
        ssh.notes = "new notes"
        draft.content = .sshKey(ssh)

        let request = try mapper.toRawCipher(draft, overlaying: stored, effectiveKeys: keys,
                                             encryptedFor: RepositoryFixtures.profileId)

        let sent = try XCTUnwrap(request.sshKey)
        XCTAssertEqual(sent.keyFingerprint, stored.sshKey?.keyFingerprint, "the stored fingerprint goes back as received")
        XCTAssertEqual(try dec(sent.keyFingerprint), fingerprint)
        XCTAssertEqual(try dec(sent.privateKey), privateKey)
        XCTAssertEqual(try dec(sent.publicKey), publicKey)

        let saved = try mapper.map(raw: request, vaultKeys: keys).item
        XCTAssertEqual(saved.content, .sshKey(SSHKeyContent(
            privateKey: privateKey, publicKey: publicKey, keyFingerprint: fingerprint,
            notes: "new notes", customFields: [])))
        XCTAssertNil(saved.editBlock)
    }

    // MARK: - Incomplete keys are not edited (tasks 3.1, 3.2)

    func testHasKeyMaterial() {
        func content(_ priv: String?, _ pub: String?, _ fp: String? = nil) -> SSHKeyContent {
            SSHKeyContent(privateKey: priv, publicKey: pub, keyFingerprint: fp, notes: nil, customFields: [])
        }
        XCTAssertTrue(content("p", "q").hasKeyMaterial, "a missing fingerprint alone does not count")
        XCTAssertTrue(content("p", "q", "f").hasKeyMaterial)
        XCTAssertFalse(content(nil, "q").hasKeyMaterial)
        XCTAssertFalse(content("p", nil).hasKeyMaterial)
        XCTAssertFalse(content("", "q").hasKeyMaterial)
        XCTAssertFalse(content("p", "").hasKeyMaterial)
    }

    func testEditBlock_sshKeyAbsentOrNull_isIncompleteSSHKey() throws {
        XCTAssertEqual(mapper.editBlock(for: try record(sshKey: nil)), .incompleteSSHKey)
        XCTAssertEqual(mapper.editBlock(for: try record(sshKey: NSNull())), .incompleteSSHKey,
                       "what Vaultwarden sends for an SSH item it hides")
    }

    func testEditBlock_missingOrEmptyKeyText_isIncompleteSSHKey() throws {
        let cases: [[String: Any]] = [
            ["publicKey": enc(publicKey), "keyFingerprint": enc(fingerprint)],
            ["privateKey": enc(privateKey), "keyFingerprint": enc(fingerprint)],
            ["privateKey": "", "publicKey": enc(publicKey)],
            ["privateKey": enc(privateKey), "publicKey": NSNull()],
        ]
        for sshKey in cases {
            XCTAssertEqual(mapper.editBlock(for: try record(sshKey: sshKey)), .incompleteSSHKey, "\(sshKey.keys.sorted())")
        }
    }

    func testMap_keyTextThatDecryptsToEmpty_isIncompleteSSHKey() throws {
        let raw = try record(sshKey: ["privateKey": enc(""), "publicKey": enc(publicKey)])
        let item = try mapper.map(raw: raw, vaultKeys: keys).item
        XCTAssertEqual(item.editBlock, .incompleteSSHKey)
    }

    func testCompleteKeyWithoutFingerprint_isEditable() throws {
        let raw = try record(sshKey: ["privateKey": enc(privateKey), "publicKey": enc(publicKey)])
        XCTAssertNil(mapper.editBlock(for: raw))
        XCTAssertNil(try mapper.map(raw: raw, vaultKeys: keys).item.editBlock)
    }

    func testIncompleteSSHKeyMessage() {
        XCTAssertEqual(EditBlockReason.incompleteSSHKey.userMessage,
                       "This SSH key is incomplete and can't be edited in Prizm. Open it in a Bitwarden app to repair it.")
    }

    // MARK: - No creation (task 4.1)

    func testOnlySSHKeysAreNotCreatable() {
        XCTAssertEqual(ItemType.allCases.filter(\.isCreatable), [.login, .card, .identity, .secureNote])
    }
}
