import XCTest
@testable import Prizm

/// The SSH key create sheet: a key is generated on open, "Generate new key" and imports replace
/// all three values at once, a refused import keeps the key (openspec change
/// `ssh-key-import-and-generation`, design D4 and D6). Real key service throughout.
@MainActor
final class SSHKeyCreateViewModelTests: XCTestCase {

    private final class NoCreate: CreateVaultItemUseCase {
        func execute(draft: DraftVaultItem) async throws -> VaultItem { VaultItem(draft) }
    }

    private func makeSUT() -> ItemEditViewModel {
        ItemEditViewModel(type: .sshKey, useCase: NoCreate(), sshKeys: SSHKeyServiceImpl())
    }

    private func key(_ sut: ItemEditViewModel) -> DraftSSHKeyContent? {
        if case .sshKey(let ssh) = sut.draft.content { return ssh }
        return nil
    }

    private func vectors() throws -> [String: String] {
        struct Vectors: Decodable {
            struct Vector: Decodable { let name, privateKey: String }
            let accepted: [Vector]
            let refused: [Vector]
        }
        let all = try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data(named: "ssh-key-vectors"))
        return Dictionary(uniqueKeysWithValues: (all.accepted + all.refused).map { ($0.name, $0.privateKey) })
    }

    func testOpening_generatesAKeyAsTheStartingState() throws {
        let sut = makeSUT()
        let ssh = try XCTUnwrap(key(sut))
        XCTAssertNotNil(ssh.privateKey)
        XCTAssertEqual(ssh.keyFingerprint, SSHKeyServiceImpl().fingerprint(forPublicKey: ssh.publicKey ?? ""))
        XCTAssertTrue(sut.offersSSHKeyActions)
        XCTAssertFalse(sut.hasChanges, "an untouched sheet discards without asking")
    }

    func testGenerateNewKey_changesAllThree() throws {
        let sut = makeSUT()
        let before = try XCTUnwrap(key(sut))
        sut.generateSSHKey()
        let after = try XCTUnwrap(key(sut))
        XCTAssertNotEqual(after.privateKey, before.privateKey)
        XCTAssertNotEqual(after.publicKey, before.publicKey)
        XCTAssertNotEqual(after.keyFingerprint, before.keyFingerprint)
        XCTAssertNil(sut.sshKeyMessage)
    }

    func testImport_acceptedKeyFillsTheFields() throws {
        let sut = makeSUT()
        let text = try XCTUnwrap(try vectors()["ed1"])
        sut.importSSHKey(text: text)
        let ssh = try XCTUnwrap(key(sut))
        XCTAssertEqual(ssh.privateKey, text)
        XCTAssertEqual(ssh.keyFingerprint, "SHA256:ROelTKrdEYu0/Aa+eMMsvr+bg7nhiMhW5/Xh3Qo71xE")
        XCTAssertNil(sut.sshKeyMessage)
    }

    func testImport_refusedKeyKeepsTheCurrentKeyAndShowsTheMessage() throws {
        let sut = makeSUT()
        let before = try XCTUnwrap(key(sut))
        sut.importSSHKey(text: try XCTUnwrap(try vectors()["passphrase-protected"]))
        XCTAssertEqual(key(sut), before)
        XCTAssertEqual(sut.sshKeyMessage, SSHKeyError.passphraseProtected.userMessage)
    }

    /// The same refusal twice is announced twice: the sheet announces on every refusal, not on a
    /// changed text (review 2026-10-30).
    func testImport_sameRefusalTwice_countsTwice() throws {
        let sut = makeSUT()
        let text = try XCTUnwrap(try vectors()["passphrase-protected"])
        sut.importSSHKey(text: text)
        sut.importSSHKey(text: text)
        XCTAssertEqual(sut.sshKeyRefusalCount, 2)
    }

    /// The file picker can fail (for example, no access to the file); the sheet says so instead of
    /// doing nothing (Constitution §V; archive pass 2026-10-30).
    func testImportFromFile_pickerFailure_showsAndAnnouncesAMessage() throws {
        let sut = makeSUT()
        let before = try XCTUnwrap(key(sut))
        sut.sshKeyFileImportFailed(CocoaError(.fileReadNoPermission))
        XCTAssertEqual(key(sut), before)
        XCTAssertEqual(sut.sshKeyMessage, ItemEditViewModel.sshKeyFileUnreadableMessage)
        XCTAssertEqual(sut.sshKeyRefusalCount, 1)
    }

    func testImportFromFile_readsAKeyAndRefusesALargeFile() throws {
        let sut = makeSUT()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyFile = dir.appendingPathComponent("id_ed25519")
        try XCTUnwrap(try vectors()["ed2"]).write(to: keyFile, atomically: true, encoding: .utf8)
        let large = dir.appendingPathComponent("large")
        try Data(repeating: 0x41, count: 64 * 1024).write(to: large)

        sut.importSSHKey(fromFile: keyFile)
        XCTAssertEqual(key(sut)?.keyFingerprint, "SHA256:NvDmqfjLzgiLoyOQTLV0U05oL2jLVUFQ8+KntYz6aJY")

        sut.importSSHKey(fromFile: large)
        XCTAssertEqual(key(sut)?.keyFingerprint, "SHA256:NvDmqfjLzgiLoyOQTLV0U05oL2jLVUFQ8+KntYz6aJY", "kept")
        XCTAssertEqual(sut.sshKeyMessage, SSHKeyError.notOpenSSHKey.userMessage)
    }

    func testSave_needsAllThreeKeyValues() throws {
        let sut = makeSUT()
        sut.draft.name = "Deploy"
        XCTAssertTrue(sut.canSave)
        sut.draft.content = .sshKey(DraftSSHKeyContent(SSHKeyContent(
            privateKey: nil, publicKey: nil, keyFingerprint: nil, notes: nil, customFields: [])))
        XCTAssertFalse(sut.canSave)
    }

    func testOtherTypes_offerNoKeyActions() {
        let sut = ItemEditViewModel(type: .login, useCase: NoCreate(), sshKeys: SSHKeyServiceImpl())
        XCTAssertFalse(sut.offersSSHKeyActions)
    }
}
