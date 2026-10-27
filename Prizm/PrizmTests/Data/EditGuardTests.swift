import XCTest
@testable import Prizm

/// An item Prizm cannot write back faithfully carries an `EditBlockReason`, set by the mapper from the
/// server record. The repository refuses a full save of it before anything is encrypted or sent,
/// while folder and favorite changes (which carry no item data) still work, and local rebuilds after
/// delete, restore and attachment changes keep the reason.
///
/// The one reason today, `hasOwnKey`, is temporary: the write path does not yet send or use the
/// item's own key, so saving such an item would re-encrypt it under the wrong key.
@MainActor
final class EditGuardTests: XCTestCase {

    private var sut: VaultRepositoryImpl!
    private var mockAPI: MockPrizmAPIClient!
    private var mockCrypto: MockPrizmCryptoService!

    private let vaultKeys = KeyedCipherBuilder.randomKeys()
    private let mapper = CipherMapper()

    private lazy var blocked = VaultItem(
        id: "keyed-1", name: "Keyed", isFavorite: false, isDeleted: false,
        creationDate: Date(timeIntervalSince1970: 1_000), revisionDate: Date(timeIntervalSince1970: 2_000),
        content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])),
        folderId: "folder-1",
        editBlock: .hasOwnKey
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

    func testKeyedRecord_mapsWithTheOwnKeyReason() throws {
        let raw = KeyedCipherBuilder.login(
            id: "k", name: "Keyed", activeKeys: vaultKeys, itemKey: KeyedCipherBuilder.randomKeys()
        )

        XCTAssertEqual(mapper.editBlock(for: raw), .hasOwnKey)
        XCTAssertEqual(try mapper.map(raw: raw, vaultKeys: vaultKeys).item.editBlock, .hasOwnKey)
    }

    func testKeylessRecord_hasNoEditBlock() throws {
        let raw = KeyedCipherBuilder.login(id: "l", name: "Keyless", activeKeys: vaultKeys)

        XCTAssertNil(mapper.editBlock(for: raw))
        XCTAssertNil(try mapper.map(raw: raw, vaultKeys: vaultKeys).item.editBlock)
    }

    // MARK: - Message

    func testOwnKeyReason_messageIsPlainLanguageWithANextStep() {
        let message = EditBlockReason.hasOwnKey.userMessage

        XCTAssertEqual(
            message,
            "Prizm can't edit items with their own encryption key yet. Edit it in the Bitwarden web vault or browser extension."
        )
        for jargon in ["blob", "partialData", "cipher"] {
            XCTAssertFalse(message.localizedCaseInsensitiveContains(jargon), "\"\(jargon)\" is jargon")
        }
    }

    func testItemNotEditable_messageIsTheReasonsMessage() {
        let error = VaultError.itemNotEditable(.hasOwnKey)

        XCTAssertEqual(error.errorDescription, EditBlockReason.hasOwnKey.userMessage)
    }

    // MARK: - Repository

    func testFullSaveOfABlockedItem_throwsItemNotEditableAndSendsNothing() async throws {
        var draft = DraftVaultItem(blocked)
        draft.name = "Renamed"

        do {
            _ = try await sut.update(draft)
            XCTFail("Expected VaultError.itemNotEditable")
        } catch VaultError.itemNotEditable(let reason) {
            XCTAssertEqual(reason, .hasOwnKey)
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
        XCTAssertEqual(afterFavorite.editBlock, .hasOwnKey)
    }

    func testSoftDeleteRestoreAndAttachmentUpdate_keepTheEditBlock() async throws {
        try await sut.deleteItem(id: blocked.id)
        let afterDelete = try await sut.itemDetail(id: blocked.id)
        XCTAssertTrue(afterDelete.isDeleted)
        XCTAssertEqual(afterDelete.editBlock, .hasOwnKey, "after soft delete")

        try await sut.restoreItem(id: blocked.id)
        let afterRestore = try await sut.itemDetail(id: blocked.id)
        XCTAssertFalse(afterRestore.isDeleted)
        XCTAssertEqual(afterRestore.editBlock, .hasOwnKey, "after restore")

        let attachment = Attachment(id: "att-1", fileName: "a.txt", encryptedKey: "2.k|k|k", size: 10,
                                    sizeName: "10 B", url: nil, isUploadIncomplete: false)
        await sut.updateAttachments([attachment], for: blocked.id)
        let after = try await sut.itemDetail(id: blocked.id)
        XCTAssertEqual(after.editBlock, .hasOwnKey, "after an attachment update")
        XCTAssertEqual(after.attachments, [attachment])
    }
}
