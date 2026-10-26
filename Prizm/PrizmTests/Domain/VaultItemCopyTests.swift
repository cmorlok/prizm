import XCTest
@testable import Prizm

/// `VaultItem.with(folderId:)` and `with(isFavorite:)` change one field and keep every other one
/// (openspec change fix-favorite-and-folder-partial-updates, design D2).
final class VaultItemCopyTests: XCTestCase {

    /// Every stored property differs from the initializer's defaults.
    private let item = VaultItem(
        id: "item-1", name: "Shared Login", isFavorite: false, isDeleted: true,
        creationDate: Date(timeIntervalSince1970: 1_000), revisionDate: Date(timeIntervalSince1970: 2_000),
        content: .secureNote(SecureNoteContent(notes: "note", customFields: [])),
        reprompt: 1,
        attachments: [Attachment(id: "att-1", fileName: "a.txt", encryptedKey: "2.k|k|k", size: 10, sizeName: "10 B",
                                url: nil, isUploadIncomplete: false)],
        folderId: "folder-1",
        organizationId: "org-1",
        collectionIds: ["col-1", "col-2"]
    )

    func testWithFolderId_changesOnlyTheFolder() {
        let moved = item.with(folderId: "folder-2")

        XCTAssertEqual(moved.folderId, "folder-2")
        XCTAssertEqual(moved, expected(folderId: "folder-2", isFavorite: item.isFavorite))
    }

    func testWithFolderId_nil_removesTheFolder() {
        XCTAssertNil(item.with(folderId: nil).folderId)
        XCTAssertEqual(item.with(folderId: nil), expected(folderId: nil, isFavorite: item.isFavorite))
    }

    func testWithIsFavorite_changesOnlyTheFavorite() {
        let favorited = item.with(isFavorite: true)

        XCTAssertTrue(favorited.isFavorite)
        XCTAssertEqual(favorited, expected(folderId: item.folderId, isFavorite: true))
    }

    /// The expected copy, spelled out field by field.
    private func expected(folderId: String?, isFavorite: Bool) -> VaultItem {
        VaultItem(
            id: item.id, name: item.name, isFavorite: isFavorite, isDeleted: item.isDeleted,
            creationDate: item.creationDate, revisionDate: item.revisionDate, content: item.content,
            reprompt: item.reprompt, attachments: item.attachments, folderId: folderId,
            organizationId: item.organizationId, collectionIds: item.collectionIds
        )
    }
}
