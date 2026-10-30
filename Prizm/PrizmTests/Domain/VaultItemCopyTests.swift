import XCTest
@testable import Prizm

/// The `VaultItem.with(...)` copies (`folderId`, `isFavorite`, `isDeleted`, `attachments`,
/// `collectionIds`) change one field and keep every other one, `editBlock` included (openspec
/// changes fix-favorite-and-folder-partial-updates, design D2, and fix-cipher-edit-data-loss).
final class VaultItemCopyTests: XCTestCase {

    /// Every stored property differs from the initializer's defaults.
    private let item = VaultItem(
        id: "item-1", name: "Shared Login", isFavorite: false, isDeleted: true,
        creationDate: Date(timeIntervalSince1970: 1_000), revisionDate: Date(timeIntervalSince1970: 2_000),
        content: .secureNote(SecureNoteContent(notes: "note", customFields: [])),
        reprompt: 1,
        attachments: [Attachment(id: "att-1", fileName: "a.txt", encryptedKey: "2.k|k|k", size: 10, sizeName: "10 B",
                                url: nil)],
        folderId: "folder-1",
        organizationId: "org-1",
        collectionIds: ["col-1", "col-2"],
        editBlock: .unsupportedFormat
    )

    func testWithFolderId_changesOnlyTheFolder() {
        let moved = item.with(folderId: "folder-2")

        XCTAssertEqual(moved.folderId, "folder-2")
        XCTAssertEqual(moved, expected(folderId: "folder-2", isFavorite: item.isFavorite))
    }

    func testWithFolderId_nil_removesTheFolder() {
        XCTAssertNil(item.with(folderId: nil).folderId)
        XCTAssertEqual(item.with(folderId: nil), expected(folderId: .some(nil), isFavorite: item.isFavorite))
    }

    func testWithIsFavorite_changesOnlyTheFavorite() {
        let favorited = item.with(isFavorite: true)

        XCTAssertTrue(favorited.isFavorite)
        XCTAssertEqual(favorited, expected(folderId: item.folderId, isFavorite: true))
    }

    // MARK: - Local rebuilds after delete, restore, attachment and collection changes

    func testWithIsDeleted_changesOnlyIsDeleted() {
        let restored = item.with(isDeleted: false)

        XCTAssertFalse(restored.isDeleted)
        XCTAssertEqual(restored, expected(isDeleted: false))
        XCTAssertEqual(restored.editBlock, .unsupportedFormat)
    }

    func testWithAttachments_changesOnlyTheAttachments() {
        let replaced = item.with(attachments: [])

        XCTAssertTrue(replaced.attachments.isEmpty)
        XCTAssertEqual(replaced, expected(attachments: []))
        XCTAssertEqual(replaced.editBlock, .unsupportedFormat)
    }

    func testWithCollectionIds_changesOnlyTheCollections() {
        let patched = item.with(collectionIds: ["col-9"])

        XCTAssertEqual(patched.collectionIds, ["col-9"])
        XCTAssertEqual(patched, expected(collectionIds: ["col-9"]))
        XCTAssertEqual(patched.editBlock, .unsupportedFormat)
    }

    func testFolderAndFavoriteCopies_keepTheEditBlock() {
        XCTAssertEqual(item.with(folderId: "x").editBlock, .unsupportedFormat)
        XCTAssertEqual(item.with(isFavorite: true).editBlock, .unsupportedFormat)
    }

    func testInitializer_editBlockDefaultsToNil() {
        let plain = VaultItem(
            id: "p", name: "Plain", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .secureNote(SecureNoteContent(notes: nil, customFields: []))
        )

        XCTAssertNil(plain.editBlock)
    }

    /// The expected copy, spelled out field by field.
    private func expected(
        folderId: String?? = .none, isFavorite: Bool? = nil, isDeleted: Bool? = nil,
        attachments: [Attachment]? = nil, collectionIds: [String]? = nil
    ) -> VaultItem {
        VaultItem(
            id: item.id, name: item.name, isFavorite: isFavorite ?? item.isFavorite,
            isDeleted: isDeleted ?? item.isDeleted,
            creationDate: item.creationDate, revisionDate: item.revisionDate, content: item.content,
            reprompt: item.reprompt, attachments: attachments ?? item.attachments,
            folderId: folderId ?? item.folderId,
            organizationId: item.organizationId, collectionIds: collectionIds ?? item.collectionIds,
            editBlock: item.editBlock
        )
    }
}
