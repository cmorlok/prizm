import XCTest
@testable import Prizm

/// An item Prizm cannot write back faithfully carries an `EditBlockReason`, set by the mapper from the
/// server record. The repository refuses a full save of it before anything is encrypted or sent,
/// while folder and favorite changes (which carry no item data) still work, and local rebuilds after
/// delete, restore and attachment changes keep the reason.
///
/// The reasons are lasting ones: a blob, a partial item, a missing type section. An item with its own
/// key is editable (saves are written with that key); the repository tests below use
/// `unsupportedFormat` as the example of a blocked item.
@MainActor
final class EditGuardTests: XCTestCase {

    private var sut: VaultRepositoryImpl!
    private var mockAPI: MockPrizmAPIClient!
    private var mockCrypto: MockPrizmCryptoService!

    private let vaultKeys = KeyedCipherBuilder.randomKeys()
    private let mapper = CipherMapper()

    private lazy var blocked = VaultItem(
        id: "blocked-1", name: "Blocked", isFavorite: false, isDeleted: false,
        creationDate: Date(timeIntervalSince1970: 1_000), revisionDate: Date(timeIntervalSince1970: 2_000),
        content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])),
        folderId: "folder-1",
        editBlock: .unsupportedFormat
    )

    override func setUp() async throws {
        try await super.setUp()
        mockAPI = MockPrizmAPIClient()
        mockCrypto = MockPrizmCryptoService()
        await mockCrypto.unlockWith(keys: vaultKeys)
        mockCrypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        sut = await RepositoryFixtures.vaultRepository(apiClient: mockAPI, crypto: mockCrypto)
        await sut.populate(
            items: [blocked], folders: [Folder(id: "folder-1", name: "One"), Folder(id: "folder-2", name: "Two")],
            organizations: [], collections: [], syncedAt: Date()
        )
    }

    // MARK: - Mapper

    func testKeyedRecord_isEditable() throws {
        let raw = KeyedCipherBuilder.login(
            id: "k", name: "Keyed", activeKeys: vaultKeys, itemKey: KeyedCipherBuilder.randomKeys()
        )

        XCTAssertNil(mapper.editBlock(for: raw))
        XCTAssertNil(try mapper.map(raw: raw, vaultKeys: vaultKeys).item.editBlock)
    }

    func testKeylessRecord_hasNoEditBlock() throws {
        let raw = KeyedCipherBuilder.login(id: "l", name: "Keyless", activeKeys: vaultKeys)

        XCTAssertNil(mapper.editBlock(for: raw))
        XCTAssertNil(try mapper.map(raw: raw, vaultKeys: vaultKeys).item.editBlock)
    }

    // MARK: - Server payload helpers

    /// `raw` as the server would send it with extra top-level keys: encoded, the keys added
    /// (`NSNull()` for JSON null), decoded again. Goes through the real decoder, which is where the
    /// guard flags are set.
    private func decoded(_ raw: RawCipher, adding extra: [String: Any]) throws -> RawCipher {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: Any])
        for (key, value) in extra { object[key] = value }
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func keylessLogin(id: String = "payload-1") -> RawCipher {
        KeyedCipherBuilder.login(id: id, name: "Payload item", username: "u", password: "p", activeKeys: vaultKeys)
    }

    // MARK: - Blob (tracer)

    func testBlobCipherFromAPayload_isListedButCannotBeEdited() async throws {
        let blob = try decoded(keylessLogin(), adding: ["data": #"{"format_version":1,"payload":"opaque"}"#])

        let mapped = try mapper.map(raw: blob, vaultKeys: vaultKeys)

        XCTAssertEqual(mapped.item.name, "Payload item", "the item is listed and decrypts as before")
        XCTAssertEqual(mapped.item.editBlock, .unsupportedFormat)

        let repo = await RepositoryFixtures.vaultRepository(apiClient: mockAPI, crypto: mockCrypto)
        await repo.populate(items: [mapped.item], folders: [], organizations: [], collections: [], syncedAt: Date())
        var draft = DraftVaultItem(mapped.item)
        draft.name = "Renamed"

        do {
            _ = try await repo.update(draft)
            XCTFail("Expected VaultError.itemNotEditable")
        } catch VaultError.itemNotEditable(let reason) {
            XCTAssertEqual(reason, .unsupportedFormat)
        }
        XCTAssertEqual(mockAPI.updateCipherCallCount, 0, "no request is sent")
    }

    // MARK: - Message

    func testItemNotEditable_messageIsTheReasonsMessage() {
        let error = VaultError.itemNotEditable(.unsupportedFormat)

        XCTAssertEqual(error.errorDescription, EditBlockReason.unsupportedFormat.userMessage)
    }

    // MARK: - Repository

    func testFullSaveOfABlockedItem_throwsItemNotEditableAndSendsNothing() async throws {
        var draft = DraftVaultItem(blocked)
        draft.name = "Renamed"

        do {
            _ = try await sut.update(draft)
            XCTFail("Expected VaultError.itemNotEditable")
        } catch VaultError.itemNotEditable(let reason) {
            XCTAssertEqual(reason, .unsupportedFormat)
        }

        XCTAssertEqual(mockAPI.updateCipherCallCount, 0, "no request is sent")
        XCTAssertEqual(mockAPI.updateCipherCollectionsCallCount, 0)
        XCTAssertTrue(mockAPI.partialUpdates.isEmpty)
        let cached = try await sut.itemDetail(id: blocked.id)
        XCTAssertEqual(cached, blocked, "the cache is untouched")
    }

    func testFolderOnlyAndFavoriteOnlyChangesOfABlockedItem_stillUsePartial() async throws {
        var folderChange = DraftVaultItem(blocked)
        folderChange.folderId = "folder-2"
        _ = try await sut.update(folderChange)

        XCTAssertEqual(mockAPI.partialUpdates.count, 1)
        XCTAssertEqual(mockAPI.partialUpdates.first?.folderId, "folder-2")

        let afterFolder = try await sut.itemDetail(id: blocked.id)
        var favoriteChange = DraftVaultItem(afterFolder)
        favoriteChange.isFavorite = true
        _ = try await sut.update(favoriteChange)

        XCTAssertEqual(mockAPI.partialUpdates.count, 2)
        XCTAssertEqual(mockAPI.partialUpdates.last?.favorite, true)
        XCTAssertEqual(mockAPI.updateCipherCallCount, 0, "no full PUT")
        let afterFavorite = try await sut.itemDetail(id: blocked.id)
        XCTAssertEqual(afterFavorite.editBlock, .unsupportedFormat)
    }

    func testSoftDeleteRestoreAndAttachmentUpdate_keepTheEditBlock() async throws {
        try await sut.deleteItem(id: blocked.id)
        let afterDelete = try await sut.itemDetail(id: blocked.id)
        XCTAssertTrue(afterDelete.isDeleted)
        XCTAssertEqual(afterDelete.editBlock, .unsupportedFormat, "after soft delete")

        try await sut.restoreItem(id: blocked.id)
        let afterRestore = try await sut.itemDetail(id: blocked.id)
        XCTAssertFalse(afterRestore.isDeleted)
        XCTAssertEqual(afterRestore.editBlock, .unsupportedFormat, "after restore")

        let attachment = Attachment(id: "att-1", fileName: "a.txt", encryptedKey: "2.k|k|k", size: 10,
                                    sizeName: "10 B", url: nil, isUploadIncomplete: false)
        await sut.updateAttachments([attachment], for: blocked.id)
        let after = try await sut.itemDetail(id: blocked.id)
        XCTAssertEqual(after.editBlock, .unsupportedFormat, "after an attachment update")
        XCTAssertEqual(after.attachments, [attachment])
    }

    // MARK: - Inline payloads

    /// A top-level cipher payload with `extra` members, decoded through the real decoder (where the
    /// guard flags are set). `extra` is raw JSON for the members, for example `"data": null`.
    private func payload(type: Int = 1, sections: String = #""login": {}"#, extra: String = "") throws -> RawCipher {
        let members = [#""id": "p-1""#, #""type": \#(type)"#, #""name": "n""#, #""favorite": false"#, sections, extra]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return try JSONDecoder().decode(RawCipher.self, from: Data("{\(members)}".utf8))
    }

    private struct CipherDocument: Decodable {
        let ciphers: [RawCipher]
    }

    // MARK: - What the official server sends on every cipher

    func testOfficialShapedCiphers_dataAndNullPartialData_doNotBlock() throws {
        let ciphers = try JSONDecoder().decode(CipherDocument.self, from: FixtureLoader.data(named: "cipher-official-shaped")).ciphers

        XCTAssertEqual(ciphers.count, 2, "the fixture must carry ciphers for this test to mean anything")
        for cipher in ciphers {
            XCTAssertFalse(cipher.hasBlobData, "Cipher \(cipher.id): a legacy data without format_version is not a blob")
            XCTAssertFalse(cipher.hasPartialData, "Cipher \(cipher.id): partialData null is not partial")
            XCTAssertNil(mapper.editBlock(for: cipher), "Cipher \(cipher.id)")
        }
    }

    func testDataThatIsNotJSONOrAnArray_doesNotBlock() throws {
        let cases: [(label: String, extra: String)] = [
            ("not JSON", #""data": "not json at all {""#),
            ("a JSON array", #""data": "[{\"format_version\": 1}]""#),
            ("an object without format_version", #""data": "{\"Name\": \"x\"}""#),
            ("an absent data key", ""),
            ("a null data", #""data": null"#),
            ("a number", #""data": 7"#),
        ]
        for (label, extra) in cases {
            let cipher = try payload(extra: extra)

            XCTAssertFalse(cipher.hasBlobData, label)
            XCTAssertNil(mapper.editBlock(for: cipher), label)
        }
    }

    func testPartialDataNull_doesNotBlock() throws {
        let cipher = try payload(extra: #""partialData": null"#)

        XCTAssertFalse(cipher.hasPartialData)
        XCTAssertNil(mapper.editBlock(for: cipher))
    }

    // MARK: - One step over each line

    func testFormatVersionValue_isNotInterpreted() throws {
        // The key's presence is the whole rule: no value, not even null or a string, makes it safe.
        for value in ["0", "1", #""2""#, "null", "{}"] {
            let asString = try payload(extra: #""data": "{\"format_version\": \#(value.replacingOccurrences(of: "\"", with: "\\\""))}""#)
            let asObject = try payload(extra: #""data": {"format_version": \#(value)}"#)

            XCTAssertTrue(asString.hasBlobData, "format_version \(value) inside a data string")
            XCTAssertTrue(asObject.hasBlobData, "format_version \(value) inside a data object")
            XCTAssertEqual(mapper.editBlock(for: asString), .unsupportedFormat, value)
        }
    }

    func testPartialDataPresentAndNotNull_blocks() throws {
        for (label, extra) in [("an object", #""partialData": {"id": "x"}"#), ("a string", #""partialData": "x""#)] {
            let cipher = try payload(extra: extra)

            XCTAssertTrue(cipher.hasPartialData, label)
            XCTAssertEqual(mapper.editBlock(for: cipher), .partiallyAvailable, label)
        }
    }

    // MARK: - Missing type section

    func testMissingStructuredObject_isUnmappable() throws {
        // An SSH key item without its object is `incompleteSSHKey` (SSHKeyIntegrityTests).
        let sections: [(type: Int, name: String)] = [(1, "login"), (3, "card"), (4, "identity")]
        for (type, name) in sections {
            let absent = try payload(type: type, sections: "")
            let null = try payload(type: type, sections: #""\#(name)": null"#)

            XCTAssertEqual(mapper.editBlock(for: absent), .unmappable, "type \(type), \(name) absent")
            XCTAssertEqual(mapper.editBlock(for: null), .unmappable, "type \(type), \(name) null")
        }
    }

    func testStructuredObjectPresent_doesNotBlock() throws {
        // An empty SSH key object has no key, so it blocks (SSHKeyIntegrityTests).
        let sections: [(type: Int, name: String)] = [(1, "login"), (3, "card"), (4, "identity")]
        for (type, name) in sections {
            XCTAssertNil(mapper.editBlock(for: try payload(type: type, sections: #""\#(name)": {}"#)), "type \(type)")
        }
    }

    func testSecureNoteWithoutItsObject_isEditable() throws {
        // Prizm writes `{ "type": 0 }` back for a secure note, so nothing is missing.
        XCTAssertNil(mapper.editBlock(for: try payload(type: 2, sections: "")))
        XCTAssertNil(mapper.editBlock(for: try payload(type: 2, sections: #""secureNote": null"#)))
    }

    // MARK: - Legacy encryption (type-0 name)

    /// A name Prizm cannot write back with a proven key: every save of such an item fails the key
    /// check, so the Edit button is disabled with a reason instead of offering a save that cannot
    /// succeed.
    func testTypeZeroName_isBlockedAsLegacyEncryption() throws {
        let typeZeroName = "0.AAAAAAAAAAAAAAAAAAAAAA==|AAAAAAAAAAAAAAAAAAAAAA=="
        let keyless = try decoded(keylessLogin(), adding: ["name": typeZeroName])
        let keyed = try decoded(
            KeyedCipherBuilder.login(id: "k", name: "Keyed", activeKeys: vaultKeys, itemKey: KeyedCipherBuilder.randomKeys()),
            adding: ["name": typeZeroName])

        XCTAssertEqual(mapper.editBlock(for: keyless), .legacyEncryption)
        XCTAssertEqual(mapper.editBlock(for: keyed), .legacyEncryption, "an item with its own key too")
    }

    func testTypeTwoName_isNotBlockedAsLegacyEncryption() {
        XCTAssertNil(mapper.editBlock(for: keylessLogin()))
    }

    // MARK: - Precedence

    func testReasonPrecedence() throws {
        let keyedBlob = try decoded(
            KeyedCipherBuilder.login(id: "kb", name: "Keyed blob", activeKeys: vaultKeys, itemKey: KeyedCipherBuilder.randomKeys()),
            adding: ["data": #"{"format_version":1}"#]
        )
        XCTAssertEqual(mapper.editBlock(for: keyedBlob), .unsupportedFormat, "a keyed blob shows the blob message")

        let partialWithoutLogin = try payload(sections: "", extra: #""partialData": {"id": "x"}"#)
        XCTAssertEqual(mapper.editBlock(for: partialWithoutLogin), .partiallyAvailable)

        let blobAndPartial = try payload(extra: #""data": {"format_version": 1}, "partialData": "x""#)
        XCTAssertEqual(mapper.editBlock(for: blobAndPartial), .unsupportedFormat)
    }

    // MARK: - Nothing of data or partialData is held or sent

    func testFlaggedCipher_encodesNoDataPartialDataOrFlag() throws {
        let plain = keylessLogin()
        let flagged = try decoded(plain, adding: [
            "data": #"{"format_version":1,"secret":"do-not-send"}"#,
            "partialData": ["id": "x"],
        ])
        XCTAssertTrue(flagged.hasBlobData && flagged.hasPartialData, "the payload must set both flags for this test to mean anything")

        func keys(_ cipher: RawCipher) throws -> Set<String> {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(cipher)) as? [String: Any])
            return Set(object.keys)
        }

        XCTAssertEqual(try keys(flagged), try keys(plain))
        for forbidden in ["data", "partialData", "hasBlobData", "hasPartialData"] {
            XCTAssertFalse(try keys(flagged).contains(forbidden), forbidden)
        }
        let sent = try String(decoding: JSONEncoder().encode(flagged), as: UTF8.self)
        XCTAssertFalse(sent.contains("do-not-send"), "the data value is never kept")
        XCTAssertFalse(String(describing: flagged).contains("do-not-send"))
    }

    func testMemberwiseInit_defaultsBothFlagsToFalse() {
        let raw = keylessLogin()

        XCTAssertFalse(raw.hasBlobData)
        XCTAssertFalse(raw.hasPartialData)
    }

    // MARK: - Messages

    func testReasonMessages_arePlainLanguageWithANextStep() {
        let reasons: [EditBlockReason] = [.unsupportedFormat, .partiallyAvailable, .unmappable, .legacyEncryption,
                                          .incompleteSSHKey]
        for reason in reasons {
            // Exhaustive on purpose: a new reason does not compile until it is listed above.
            switch reason {
            case .unsupportedFormat, .partiallyAvailable, .unmappable, .legacyEncryption, .incompleteSSHKey: break
            }
            let message = reason.userMessage

            // The next step: where to edit or repair the item.
            XCTAssertTrue(message.contains("Bitwarden web vault or browser extension.") || message.contains("Bitwarden app"),
                          "\(reason)")
            for jargon in ["blob", "partialData", "format_version", "JSON", "cipher"] {
                XCTAssertFalse(message.localizedCaseInsensitiveContains(jargon), "\(reason) mentions \"\(jargon)\"")
            }
        }
        XCTAssertEqual(Set(reasons.map(\.userMessage)).count, reasons.count, "each reason says something different")
    }

    // MARK: - Blocked items still star and move

    func testBlockedItem_stillStarsAndMovesThroughPartial() async throws {
        let partial = try decoded(keylessLogin(id: "partial-1"), adding: ["partialData": "x"])
        let item = try mapper.map(raw: partial, vaultKeys: vaultKeys).item
        XCTAssertEqual(item.editBlock, .partiallyAvailable)
        let repo = await RepositoryFixtures.vaultRepository(apiClient: mockAPI, crypto: mockCrypto)
        await repo.populate(
            items: [item], folders: [Folder(id: "folder-1", name: "One")],
            organizations: [], collections: [], syncedAt: Date()
        )

        var star = DraftVaultItem(item)
        star.isFavorite = true
        _ = try await repo.update(star)
        let afterStar = try await repo.itemDetail(id: item.id)
        var move = DraftVaultItem(afterStar)
        move.folderId = "folder-1"
        _ = try await repo.update(move)

        XCTAssertEqual(mockAPI.partialUpdates.count, 2)
        XCTAssertEqual(mockAPI.partialUpdates.first?.favorite, true)
        XCTAssertEqual(mockAPI.partialUpdates.last?.folderId, "folder-1")
        XCTAssertEqual(mockAPI.updateCipherCallCount, 0, "no full PUT")
        let after = try await repo.itemDetail(id: item.id)
        XCTAssertEqual(after.editBlock, .partiallyAvailable)
    }
}
