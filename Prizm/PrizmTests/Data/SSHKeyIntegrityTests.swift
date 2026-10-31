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

    // MARK: - Fingerprints on create and save (ssh-key-import-and-generation, D5)

    private func sshDraft(_ material: SSHKeyMaterial, fingerprint: String? = nil) -> DraftVaultItem {
        var draft = DraftVaultItem.blank(type: .sshKey)
        draft.name = "New key"
        guard case .sshKey(var ssh) = draft.content else { return draft }
        ssh.replace(with: material)
        if let fingerprint {
            ssh = DraftSSHKeyContent(SSHKeyContent(privateKey: material.privateKey, publicKey: material.publicKey,
                                                   keyFingerprint: fingerprint, notes: nil, customFields: []))
        }
        draft.content = .sshKey(ssh)
        return draft
    }

    func testCreate_sendsTheComputedFingerprint() throws {
        let material = try SSHKeyServiceImpl().generate()
        let request = try mapper.toUnkeyedRawCipher(sshDraft(material), encryptedWith: keys,
                                                encryptedFor: RepositoryFixtures.profileId)
        let sent = try XCTUnwrap(request.sshKey)
        XCTAssertEqual(try dec(sent.keyFingerprint), material.fingerprint)
        XCTAssertEqual(try dec(sent.publicKey), material.publicKey)
        XCTAssertEqual(try dec(sent.privateKey), material.privateKey)
    }

    func testCreate_refusesAFingerprintThatDoesNotMatch() throws {
        let material = try SSHKeyServiceImpl().generate()
        XCTAssertThrowsError(try mapper.toUnkeyedRawCipher(sshDraft(material, fingerprint: "SHA256:wrong"),
                                                       encryptedWith: keys, encryptedFor: RepositoryFixtures.profileId)) {
            XCTAssertEqual($0 as? CipherMapperError, .sshKeyFingerprintMismatch)
        }
    }

    /// A new SSH item without all three values would be hidden by Vaultwarden; the repository refuses
    /// it before anything is sent, although the sheet never offers one (review 2026-10-30).
    func testCreate_refusesAKeyWithoutAllThreeValues() async throws {
        let rig = await StaleWriteRig.make()
        let material = try SSHKeyServiceImpl().generate()
        var withoutFingerprint = sshDraft(material)
        if case .sshKey(let ssh) = withoutFingerprint.content {
            withoutFingerprint.content = .sshKey(DraftSSHKeyContent(SSHKeyContent(
                privateKey: ssh.privateKey, publicKey: ssh.publicKey, keyFingerprint: nil, notes: nil, customFields: [])))
        }
        var empty = DraftVaultItem.blank(type: .sshKey)
        empty.name = "Empty key"
        for draft in [empty, withoutFingerprint] {
            do {
                _ = try await rig.vault.create(draft)
                XCTFail("An incomplete SSH key must be refused")
            } catch {
                XCTAssertEqual(error as? CipherMapperError, .sshKeyIncomplete, "Got \(error)")
            }
        }
        XCTAssertEqual(rig.api.createCipherCallCount, 0, "Nothing is sent")
    }

    func testEdit_fillsInAMissingOrBlankFingerprint() throws {
        let material = try SSHKeyServiceImpl().generate()
        for stored: Any? in [nil, enc(""), enc("  ")] {
            var sshKey: [String: Any] = ["privateKey": enc(material.privateKey), "publicKey": enc(material.publicKey)]
            if let stored { sshKey["keyFingerprint"] = stored }
            let raw = try record(sshKey: sshKey)
            let draft = DraftVaultItem(try mapper.map(raw: raw, vaultKeys: keys).item)
            let request = try mapper.toRawCipher(draft, overlaying: raw, effectiveKeys: keys,
                                                 encryptedFor: RepositoryFixtures.profileId)
            XCTAssertEqual(try dec(request.sshKey?.keyFingerprint), material.fingerprint, "stored \(String(describing: stored))")
        }
    }

    func testEdit_keepsADifferentStoredFingerprint() throws {
        // `publicKey` above is not a real key, so its computed fingerprint would differ or be nil.
        let stored = try completeRecord()
        let request = try mapper.toRawCipher(DraftVaultItem(try mapper.map(raw: stored, vaultKeys: keys).item),
                                             overlaying: stored, effectiveKeys: keys, encryptedFor: RepositoryFixtures.profileId)
        XCTAssertEqual(request.sshKey?.keyFingerprint, stored.sshKey?.keyFingerprint)
    }

    func testEdit_unreadablePublicKeySendsNoFingerprint() throws {
        let raw = try record(sshKey: ["privateKey": enc(privateKey), "publicKey": enc("not a public key")])
        let request = try mapper.toRawCipher(DraftVaultItem(try mapper.map(raw: raw, vaultKeys: keys).item),
                                             overlaying: raw, effectiveKeys: keys, encryptedFor: RepositoryFixtures.profileId)
        XCTAssertNil(request.sshKey?.keyFingerprint)
    }
}
