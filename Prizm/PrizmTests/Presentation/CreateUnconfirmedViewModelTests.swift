import XCTest
@testable import Prizm

/// A create the server answered without the generated item key exists on the server, so the sheet
/// must not offer Save again: a second save would create a duplicate (per-item-key-on-create, D4).
@MainActor
final class CreateUnconfirmedViewModelTests: XCTestCase {

    private struct UnconfirmedCreate: CreateVaultItemUseCase {
        func execute(draft: DraftVaultItem) async throws -> VaultItem { throw VaultError.createdButUnconfirmed }
    }

    func testUnconfirmedCreate_showsItsTextAndBlocksSave() async throws {
        let sut = ItemEditViewModel(type: .secureNote, useCase: UnconfirmedCreate())
        sut.draft.name = "New note"
        sut.save()
        for _ in 0..<200 where sut.isSaving { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertEqual(sut.conflict, .createdButUnconfirmed)
        XCTAssertEqual(sut.bannerMessage, "Saved, but Prizm couldn't confirm the new item. Sync to see it.")
        XCTAssertFalse(sut.canSave, "a second Save would create a duplicate")
        XCTAssertFalse(sut.isDismissed, "the user closes the sheet")
        XCTAssertTrue(sut.hasChanges)
        XCTAssertFalse(sut.asksBeforeDiscard, "the item was saved: no \"changes will be lost\" prompt")
    }
}
