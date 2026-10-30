import XCTest
@testable import Prizm

/// The edit sheet's collection checkboxes and the required collection (openspec change
/// `fix-collection-assignment`, design D2–D5).
@MainActor
final class CollectionPickerViewModelTests: XCTestCase {

    private let org = "org-1"
    private lazy var collections = [
        OrgCollection(id: "B", organizationId: org, name: "Beta"),
        OrgCollection(id: "A", organizationId: org, name: "alpha"),
        OrgCollection(id: "C", organizationId: org, name: "Gamma"),
        OrgCollection(id: "R", organizationId: org, name: "Read only", readOnly: true),
        OrgCollection(id: "R2", organizationId: org, name: "Other read only", readOnly: true),
        OrgCollection(id: "O", organizationId: "org-2", name: "Other org"),
    ]

    private struct StubEdit: EditVaultItemUseCase {
        var error: Error?
        func execute(draft: DraftVaultItem) async throws -> VaultItem {
            if let error { throw error }
            return VaultItem(id: draft.id, name: draft.name, isFavorite: false, isDeleted: false,
                             creationDate: draft.creationDate, revisionDate: draft.revisionDate,
                             content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
        }
    }

    private struct StubCreate: CreateVaultItemUseCase {
        func execute(draft: DraftVaultItem) async throws -> VaultItem { fatalError("not saved in these tests") }
    }

    private func item(collectionIds: [String], organizationId: String? = "org-1") -> VaultItem {
        VaultItem(id: "i1", name: "Shared", isFavorite: false, isDeleted: false,
                  creationDate: Date(), revisionDate: Date(),
                  content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
                  organizationId: organizationId, collectionIds: collectionIds)
    }

    private func editing(_ ids: [String], error: Error? = nil) -> ItemEditViewModel {
        ItemEditViewModel(item: item(collectionIds: ids), useCase: StubEdit(error: error), collections: collections)
    }

    // MARK: - 3.1 Lists

    func testWritableCollections_areTheOrgsWritableOnes_sortedByName() {
        XCTAssertEqual(editing(["A"]).writableCollections.map(\.id), ["A", "B", "C"])
    }

    func testReadOnlyAssignments_areOnlyTheOnesTheItemIsIn() {
        XCTAssertEqual(editing(["A", "R"]).readOnlyAssignments.map(\.id), ["R"])
    }

    func testCheckedState_followsTheItem() {
        let sut = editing(["A", "B"])
        XCTAssertTrue(sut.isCollectionChecked("A"))
        XCTAssertTrue(sut.isCollectionChecked("B"))
        XCTAssertFalse(sut.isCollectionChecked("C"))
    }

    // MARK: - 1.2 / 3.1 Toggling keeps what the user did not change

    func testCheckingAnother_keepsTheExistingOnes() {
        let sut = editing(["A", "B"])
        sut.setCollection("C", checked: true)
        XCTAssertEqual(sut.draft.collectionIds, ["A", "B", "C"], "B stays: the old picker replaced it")
    }

    func testUnchecking_removesOnlyThatOne_andKeepsReadOnlyAndUnknown() {
        let sut = editing(["A", "R", "X", "B"])
        sut.setCollection("A", checked: false)
        XCTAssertEqual(sut.draft.collectionIds, ["R", "X", "B"])
        sut.setCollection("A", checked: true)
        XCTAssertEqual(sut.draft.collectionIds, ["A", "R", "X", "B"], "Back in its original place")
    }

    func testReadOnlyCollectionCannotBeAdded() {
        let sut = editing(["A"])
        sut.setCollection("R", checked: true)
        XCTAssertEqual(sut.draft.collectionIds, ["A"])
    }

    // MARK: - 4.1 Required collection

    func testUncheckingTheLastOne_disablesSave_andShowsTheHint() {
        let sut = editing(["A"])
        XCTAssertTrue(sut.canSave)
        XCTAssertNil(sut.collectionHint)

        sut.setCollection("A", checked: false)

        XCTAssertFalse(sut.canSave)
        XCTAssertEqual(sut.collectionHint, "Choose at least one collection.")
    }

    func testItemOnlyInAReadOnlyCollection_canStillBeSaved() {
        let sut = editing(["R"])
        XCTAssertTrue(sut.canSave)
        XCTAssertNil(sut.collectionHint)
    }

    func testPersonalItem_needsNoCollection() {
        let sut = ItemEditViewModel(item: item(collectionIds: [], organizationId: nil), useCase: StubEdit(),
                                    collections: collections)
        XCTAssertTrue(sut.canSave)
        XCTAssertNil(sut.collectionHint)
        XCTAssertTrue(sut.writableCollections.isEmpty)
    }

    func testCreate_withoutCollection_cannotBeSaved() {
        let sut = ItemEditViewModel(type: .secureNote, useCase: StubCreate(), organizationId: org,
                                    collectionIds: [], collections: collections)
        sut.draft.name = "New"
        XCTAssertFalse(sut.canSave)
        XCTAssertEqual(sut.collectionHint, ItemEditViewModel.collectionRequiredHint)
    }

    func testCreate_prefillsOnlyAWritableCollection() {
        let writable = ItemEditViewModel(type: .secureNote, useCase: StubCreate(), organizationId: org,
                                         collectionIds: ["B"], collections: collections)
        XCTAssertEqual(writable.draft.collectionIds, ["B"])

        let readOnly = ItemEditViewModel(type: .secureNote, useCase: StubCreate(), organizationId: org,
                                         collectionIds: ["R"], collections: collections)
        XCTAssertEqual(readOnly.draft.collectionIds, [], "The server would refuse a create into a read-only collection")
    }

    // MARK: - 5.7 Access lost through the change

    func testSavedButAccessLost_showsTheMessage_blocksSave_andOffersClose() async throws {
        let sut = editing(["A"], error: VaultError.savedButAccessLost)
        var removed: [String] = []
        sut.onItemRemoved = { removed.append($0) }
        sut.setCollection("A", checked: false)
        sut.setCollection("B", checked: true)

        sut.save()
        let deadline = ContinuousClock.now + .milliseconds(500)
        while sut.conflict != .accessLost, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(sut.bannerMessage, "Saved. You no longer have access to this item.")
        XCTAssertFalse(sut.canSave)
        XCTAssertEqual(sut.conflictActionTitle, "Close")
        XCTAssertTrue(sut.isItemGone, "Delete Item is hidden")
        XCTAssertEqual(removed, ["i1"])
        XCTAssertFalse(sut.isDismissed)

        sut.performConflictAction()
        XCTAssertTrue(sut.isDismissed)
    }
}
