import XCTest
@testable import Prizm

/// Adding, renaming, removing and moving custom fields in the edit sheet (openspec change
/// `vault-browsing-parity`, design D6, tasks 5.1, 5.3 and the announcement text of 5.4).
final class CustomFieldEditingTests: XCTestCase {

    private func read(_ name: String?, _ type: CustomFieldType = .text, value: String? = "v",
                      linkedId: LinkedFieldId? = nil) -> DraftCustomField {
        DraftCustomField(CustomField(name: name, value: value, type: type, linkedId: linkedId))
    }

    // MARK: - New fields

    func testNewField_isNew_withAnEmptyName_andNeedsOne() {
        let field = DraftCustomField(newOfType: .hidden, for: .login)
        XCTAssertTrue(field.isNew)
        XCTAssertEqual(field.name, "")
        XCTAssertNil(field.value)
        XCTAssertEqual(field.type, .hidden)
        XCTAssertTrue(field.isMissingName)
    }

    func testNewCheckbox_startsUnchecked() {
        XCTAssertEqual(DraftCustomField(newOfType: .boolean, for: .card).value, "false")
    }

    func testNewLinkedField_preselectsTheFirstTarget() {
        XCTAssertEqual(DraftCustomField(newOfType: .linked, for: .login).linkedId, .loginUsername)
        XCTAssertEqual(DraftCustomField(newOfType: .linked, for: .card).linkedId, .cardCardholderName)
        XCTAssertEqual(DraftCustomField(newOfType: .linked, for: .identity).linkedId, .identityTitle)
        XCTAssertNil(DraftCustomField(newOfType: .text, for: .login).linkedId)
    }

    func testNewField_named_needsNoMore() {
        var field = DraftCustomField(newOfType: .text, for: .login)
        field.nameText = "PIN"
        XCTAssertEqual(field.name, "PIN")
        XCTAssertFalse(field.isMissingName)
    }

    // MARK: - Names of read fields

    func testReadField_keepsTheNameItWasReadWith() {
        var field = read("PIN")
        field.nameText = "Code"
        XCTAssertEqual(field.originalName, "PIN")
        XCTAssertFalse(field.isNew)
    }

    func testNamedField_clearedToEmpty_isMissingAName() {
        var field = read("PIN")
        field.nameText = ""
        XCTAssertEqual(field.name, "")
        XCTAssertTrue(field.isMissingName)
    }

    func testWhitespaceOnlyName_isMissingAName() {
        var added = DraftCustomField(newOfType: .text, for: .login)
        added.nameText = "   "
        XCTAssertTrue(added.isMissingName)
        var read = read("PIN")
        read.nameText = " \n"
        XCTAssertTrue(read.isMissingName)
    }

    func testNamelessField_typedAndCleared_goesBackToNil() {
        var field = read(nil)
        XCTAssertFalse(field.isMissingName, "a field read without a name may stay without one")
        field.nameText = "x"
        XCTAssertEqual(field.name, "x")
        field.nameText = ""
        XCTAssertNil(field.name)
        XCTAssertFalse(field.isMissingName)
    }

    func testUnknownTypeField_canBeRenamed() {
        var field = read("Future", CustomFieldType(rawValue: 9))
        field.nameText = "Renamed"
        XCTAssertEqual(field.name, "Renamed")
        XCTAssertEqual(field.type.rawValue, 9)
    }

    // MARK: - Equality ignores the draft-only identity

    func testEquality_ignoresTheDraftId() {
        XCTAssertEqual(read("A"), read("A"))
        XCTAssertNotEqual(read("A").id, read("A").id)
    }

    func testOpeningAndCancelling_isNoChange() {
        let item = VaultItem(
            id: "i", name: "Item", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .secureNote(SecureNoteContent(notes: nil, customFields: [
                CustomField(name: "A", value: "1", type: .text, linkedId: nil)])))
        XCTAssertEqual(DraftVaultItem(item), DraftVaultItem(item))
    }

    // MARK: - Moving and removing

    func testMoveUp_andDown_returnTheNewPosition() {
        var fields = [read("Question 1"), read("Question 2"), read("Question 3")]
        let second = fields[1].id
        XCTAssertEqual(fields.moveField(id: second, by: -1), 0)
        XCTAssertEqual(fields.map(\.name), ["Question 2", "Question 1", "Question 3"])
        XCTAssertEqual(fields.moveField(id: second, by: 1), 1)
        XCTAssertEqual(fields.map(\.name), ["Question 1", "Question 2", "Question 3"])
    }

    func testMovePastAnEnd_doesNothing() {
        var fields = [read("A"), read("B")]
        XCTAssertNil(fields.moveField(id: fields[0].id, by: -1))
        XCTAssertNil(fields.moveField(id: fields[1].id, by: 1))
        XCTAssertNil(fields.moveField(id: UUID(), by: 1))
        XCTAssertEqual(fields.map(\.name), ["A", "B"])
    }

    func testRemove_dropsOnlyThatField_unknownTypeToo() {
        var fields = [read("A"), read("Future", CustomFieldType(rawValue: 9)), read("B")]
        fields.removeField(id: fields[1].id)
        XCTAssertEqual(fields.map(\.name), ["A", "B"])
    }

    func testHasMissingName() {
        var fields = [read("A"), read(nil)]
        XCTAssertFalse(fields.hasMissingName)
        fields.append(DraftCustomField(newOfType: .text, for: .login))
        XCTAssertTrue(fields.hasMissingName)
    }

    // MARK: - The content's fields

    func testContentCustomFields_readAndWriteEveryType() {
        for type in ItemType.allCases {
            var content = DraftVaultItem.blank(type: type).content
            XCTAssertEqual(content.itemType, type)
            content.customFields.append(read("A"))
            XCTAssertEqual(content.customFields.map(\.name), ["A"], type.rawValue)
        }
    }

    // MARK: - 5.3 Linked targets

    func testLinkedOptions_perItemType() {
        XCTAssertEqual(LinkedFieldId.options(for: .login), [.loginUsername, .loginPassword])
        XCTAssertEqual(LinkedFieldId.options(for: .card),
                       [.cardCardholderName, .cardExpMonth, .cardExpYear, .cardCode, .cardBrand, .cardNumber])
        XCTAssertEqual(LinkedFieldId.options(for: .identity).count, 19)
        XCTAssertEqual(LinkedFieldId.options(for: .identity).first, .identityTitle)
        XCTAssertFalse(LinkedFieldId.options(for: .identity).contains(.loginUsername))
        XCTAssertEqual(LinkedFieldId.options(for: .secureNote), [])
        XCTAssertEqual(LinkedFieldId.options(for: .sshKey), [])
    }

    func testLinkedField_targetCanBeChanged() {
        var field = DraftCustomField(newOfType: .linked, for: .login)
        field.linkedId = .loginPassword
        XCTAssertEqual(field.linkedId, .loginPassword)
    }
}

/// The edit sheet blocks Save while a custom field is missing its name (design D6).
@MainActor
final class CustomFieldEditViewModelTests: XCTestCase {

    private struct StubEdit: EditVaultItemUseCase {
        func execute(draft: DraftVaultItem) async throws -> VaultItem { VaultItem(draft) }
    }

    private let item = VaultItem(
        id: "i", name: "Item", isFavorite: false, isDeleted: false,
        creationDate: Date(), revisionDate: Date(),
        content: .login(LoginContent(username: nil, password: nil, uris: [], totp: nil, notes: nil, customFields: [
            CustomField(name: "PIN", value: "1", type: .hidden, linkedId: nil)])))

    func testUntouched_hasNoChanges_andCanSave() {
        let sut = ItemEditViewModel(item: item, useCase: StubEdit())
        XCTAssertFalse(sut.hasChanges)
        XCTAssertTrue(sut.canSave)
    }

    func testNewFieldWithoutName_blocksSave_withAHint() {
        let sut = ItemEditViewModel(item: item, useCase: StubEdit())
        sut.draft.content.customFields.append(DraftCustomField(newOfType: .text, for: .login))
        XCTAssertTrue(sut.hasChanges)
        XCTAssertFalse(sut.canSave)
        XCTAssertEqual(sut.saveBlockedHint, ItemEditViewModel.customFieldNameRequiredHint)
        sut.draft.content.customFields[1].nameText = "Note"
        XCTAssertTrue(sut.canSave)
        XCTAssertNil(sut.saveBlockedHint)
    }

    func testClearedName_blocksSave() {
        let sut = ItemEditViewModel(item: item, useCase: StubEdit())
        sut.draft.content.customFields[0].nameText = ""
        XCTAssertFalse(sut.canSave)
    }

    /// Spec scenario "Remove a field and cancel" for a field the item already had: the removal is a
    /// change (Discard asks first), nothing is saved, and the item keeps its field (verify 2026-10-31).
    func testRemovingAnExistingField_isAChange_andCancelKeepsIt() {
        final class CountingEdit: EditVaultItemUseCase, @unchecked Sendable {
            var calls = 0
            func execute(draft: DraftVaultItem) async throws -> VaultItem { calls += 1; return VaultItem(draft) }
        }
        let edit = CountingEdit()
        let sut = ItemEditViewModel(item: item, useCase: edit)
        guard let pin = sut.draft.content.customFields.first else { return XCTFail("no field") }
        sut.draft.content.customFields.removeField(id: pin.id)

        XCTAssertTrue(sut.hasChanges, "Discard asks before the removal is lost")
        XCTAssertEqual(edit.calls, 0, "nothing is saved without Save")
        guard case .login(let login) = item.content else { return XCTFail("not a login") }
        XCTAssertEqual(login.customFields.map(\.name), ["PIN"], "the item keeps its field")
    }

    func testAddedAndRemovedAgain_isNoChange() {
        let sut = ItemEditViewModel(item: item, useCase: StubEdit())
        let added = DraftCustomField(newOfType: .text, for: .login)
        sut.draft.content.customFields.append(added)
        sut.draft.content.customFields.removeField(id: added.id)
        XCTAssertFalse(sut.hasChanges)
    }
}

/// The text announced after a move (design D6, task 5.4).
@MainActor
final class CustomFieldLabelsTests: XCTestCase {

    func testMoveAnnouncement() {
        XCTAssertEqual(CustomFieldLabels.moved("Question 2", to: 1, of: 2), "Question 2 moved to position 1 of 2")
    }

    func testAccessibilityName_ofNewAndNamelessFields() {
        XCTAssertEqual(CustomFieldLabels.accessibilityName(of: DraftCustomField(newOfType: .text, for: .login)),
                       CustomFieldLabels.newField)
        XCTAssertEqual(CustomFieldLabels.accessibilityName(of: DraftCustomField(
            CustomField(name: nil, value: nil, type: .text, linkedId: nil))), CustomFieldLabels.unnamed)
        XCTAssertEqual(CustomFieldLabels.accessibilityName(of: DraftCustomField(
            CustomField(name: "PIN", value: nil, type: .text, linkedId: nil))), "PIN")
    }
}
