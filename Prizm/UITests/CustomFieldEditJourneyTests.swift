import XCTest

/// XCUITest: adding, renaming, moving and removing custom fields in the edit sheet (openspec change
/// `vault-browsing-parity`, task 5.7). Sheet only: the journey ends with Discard, so it needs no
/// server; saving and reopening is checked on the rig (task 5.8).
final class CustomFieldEditJourneyTests: PrizmUITestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch(in: UITestLaunch.vault)
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func addField(_ type: String) {
        let add = app.descendants(matching: .any)[AccessibilityID.Edit.addCustomField].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3), "The Add Field menu is shown")
        add.click()
        let item = app.menuItems[type]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Add Field offers \(type)")
        item.click()
    }

    private func nameField(_ index: Int) -> XCUIElement {
        app.textFields[AccessibilityID.Edit.customFieldName(index)]
    }

    /// Names avoid the letter "c": XCUITest's typeText drops it in this app's text fields.
    private func name(_ index: Int, _ text: String) {
        let field = nameField(index)
        XCTAssertTrue(field.waitForExistence(timeout: 3), "Field \(index) has a name field")
        field.click()
        field.typeText(text)
    }

    func testAddRenameMoveRemove_inTheSheet() {
        let row = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let edit = app.buttons[AccessibilityID.Edit.editButton]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.click()
        let save = app.buttons[AccessibilityID.Edit.saveButton]
        XCTAssertTrue(save.waitForExistence(timeout: 3), "The edit sheet opens")

        // A new field needs a name before Save works.
        addField("Text")
        let required = app.staticTexts[AccessibilityID.Edit.customFieldNameRequired(0)]
        XCTAssertTrue(required.waitForExistence(timeout: 3), "The row says a name is required")
        XCTAssertFalse(save.isEnabled, "Save waits for the name")
        name(0, "Question 1")
        XCTAssertFalse(required.waitForExistence(timeout: 1), "The note goes once the field has a name")
        XCTAssertTrue(save.isEnabled)

        addField("Hidden")
        name(1, "Question 2")

        // Move the second field up: it becomes the first.
        let moveUp = app.buttons[AccessibilityID.Edit.customFieldMoveUp(1)]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 3))
        moveUp.click()
        XCTAssertEqual(nameField(0).value as? String, "Question 2")
        XCTAssertEqual(nameField(1).value as? String, "Question 1")

        // Remove the second field.
        app.buttons[AccessibilityID.Edit.customFieldRemove(1)].click()
        XCTAssertFalse(nameField(1).waitForExistence(timeout: 1), "One field is left")
        XCTAssertEqual(nameField(0).value as? String, "Question 2")

        // Discard: the item keeps no new field.
        app.buttons[AccessibilityID.Edit.discardButton].click()
        let confirm = app.windows.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.click()
        XCTAssertFalse(save.waitForExistence(timeout: 3), "The sheet closes")
        XCTAssertFalse(app.staticTexts["Question 2"].exists, "The detail shows no added field")
    }
}
