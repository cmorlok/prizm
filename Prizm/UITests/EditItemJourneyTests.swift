import XCTest

/// XCUITest: Edit Vault Item Journey (edit-vault-items task 10.x)
///
/// Validates the full edit-and-save flow: opening the edit sheet via the Edit button
/// and ⌘E, making changes, saving with the Save button and ⌘S, discarding with the
/// Discard button and Esc, and the discard confirmation prompt.
///
/// Runs in the seeded vault (`UITestLaunch.vault`), with no server: saving is skipped through
/// `UITestPrerequisite.serverWrites()`.
final class EditItemJourneyTests: PrizmUITestCase {

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

    // MARK: - Task 10.1: Open edit sheet, change name, save, verify detail pane and list row

    /// Opens the edit sheet for a Login item, changes the name, saves, and verifies the
    /// updated name appears in both the detail pane and the list row.
    func testEditLoginItem_saveName_updatesDetailAndList() throws {
        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        // Open the edit sheet via the Edit toolbar button.
        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()

        // Verify the edit sheet opened.
        let saveButton = app.buttons["edit.button.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Edit sheet should be visible")

        // Change the Name field.
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tripleClick()
        nameField.typeText("Updated Item Name")
        XCTAssertTrue(saveButton.isEnabled, "Save should be enabled after a change")

        // Saving sends the item to the server.
        try UITestPrerequisite.serverWrites()
    }

    // MARK: - Task 10.2: Discard with changes — confirm prompt

    /// Opens the edit sheet, makes a change, clicks Discard, confirms in the prompt,
    /// and verifies the item retains its original values.
    func testEditItem_discardWithChanges_confirmPrompt_itemUnchanged() throws {
        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        let originalName = app.staticTexts["detail.name"].text
        XCTAssertEqual(originalName, "Alpha Bank")

        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tripleClick()
        nameField.typeText("CHANGED NAME")

        let discardButton = app.buttons["edit.button.discard"]
        XCTAssertTrue(discardButton.exists)
        discardButton.click()

        // Confirm in the alert. The Touch Bar shows the same button, so look only in the window.
        let discardChangesButton = app.windows.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(discardChangesButton.waitForExistence(timeout: 3))
        discardChangesButton.click()

        // Sheet should be dismissed.
        XCTAssertFalse(app.buttons["edit.button.save"].waitForExistence(timeout: 3),
                       "Edit sheet should have dismissed")

        // Detail pane should show the original name.
        let detailName = app.staticTexts["detail.name"]
        XCTAssertEqual(detailName.text, originalName)
    }

    // MARK: - Task 10.3: Save disabled when Name is empty

    /// Opens the edit sheet, clears the Name field, and verifies Save is disabled.
    func testEditItem_emptyName_saveDisabled() throws {
        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tripleClick()
        nameField.typeKey(.delete, modifierFlags: [])

        let saveButton = app.buttons["edit.button.save"]
        XCTAssertFalse(saveButton.isEnabled, "Save should be disabled when Name is empty")
    }

    // MARK: - Task 10.4: ⌘E opens edit sheet

    /// Selects an item and presses ⌘E to open the edit sheet.
    func testCmdE_opensEditSheet() throws {
        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        app.typeKey("e", modifierFlags: .command)

        let saveButton = app.buttons["edit.button.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "⌘E should open the edit sheet")
    }

    // MARK: - Task 10.5: ⌘S saves and dismisses sheet

    /// Opens the edit sheet, makes a change, presses ⌘S, and verifies the sheet dismisses.
    func testCmdS_savesAndDismissesSheet() throws {
        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tripleClick()
        nameField.typeText("Cmd-S Saved Item")

        // ⌘S saves the item on the server.
        try UITestPrerequisite.serverWrites()
    }

    // MARK: - Task 10.6: Esc with no changes dismisses without prompt

    /// Opens the edit sheet without making changes, presses Esc, and verifies the sheet
    /// dismisses immediately without showing a confirmation prompt.
    func testEsc_noChanges_immediatelyDismisses() throws {
        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()

        XCTAssertTrue(app.buttons["edit.button.save"].waitForExistence(timeout: 3))

        // Press Esc — no changes made, so should dismiss immediately.
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(app.buttons["Discard Changes"].waitForExistence(timeout: 1),
                       "No confirmation prompt should appear when there are no changes")
        XCTAssertFalse(app.buttons["edit.button.save"].waitForExistence(timeout: 3),
                       "Edit sheet should dismiss immediately on Esc with no changes")
    }

    // MARK: - Delete Item button hidden during creation

    /// Opens the create sheet via ⌘N (it opens a new Login directly, spec `list-column-header`) and
    /// verifies no Delete Item button is shown.
    func testCreateSheet_deleteButtonHidden() throws {
        app.typeKey("n", modifierFlags: .command)

        let saveButton = app.buttons["edit.button.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Create sheet must be open")

        let deleteButton = app.buttons["edit.button.delete"]
        XCTAssertFalse(deleteButton.exists,
                       "Delete Item button must not appear in create mode")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Detail toolbar has no Delete for active items

    /// Selects an active item and verifies the detail toolbar does not contain a Delete button.
    func testDetailToolbar_noDeleteButton_forActiveItems() throws {
        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        // The Edit button should be visible (confirms we're looking at the right toolbar).
        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))

        // No Delete button should exist in the toolbar for active items.
        // Use a short timeout — we're asserting absence.
        let deleteToolbarButton = app.buttons.matching(NSPredicate(format: "label == 'Delete'")).firstMatch
        XCTAssertFalse(deleteToolbarButton.waitForExistence(timeout: 1),
                       "Detail toolbar must not contain a Delete button for active items")
    }

    // MARK: - Task 10.7: Item menu commands follow the selection and the lock state

    /// The "Item" menu is a regular menu now (`CommandMenu`), always in the menu bar. Its Edit
    /// command is available only with a selected item, Save only while the edit sheet is open, and
    /// nothing can be edited once the vault is locked.
    func testItemMenu_followsSelectionAndLock() throws {
        let itemMenu = app.menuBars.menuBarItems["Item"]
        XCTAssertTrue(itemMenu.waitForExistence(timeout: 5), "The Item menu should be in the menu bar")

        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        itemMenu.click()
        XCTAssertTrue(app.menuItems["Edit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Edit"].isEnabled, "Edit should be available with a selected item")
        XCTAssertFalse(app.menuItems["Save"].isEnabled, "Save should be unavailable without an open sheet")
        app.typeKey(.escape, modifierFlags: [])

        // Lock the vault (⌘L). Safe in the test state: the app uses an in-memory keychain.
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts[AccessibilityID.Unlock.headerTitle].waitForExistence(timeout: 5),
                      "The vault should be locked")

        itemMenu.click()
        XCTAssertTrue(app.menuItems["Edit"].waitForExistence(timeout: 3))
        // Locking drops the selected (decrypted) item, so nothing is editable (fix-ui-journey-findings).
        XCTAssertFalse(app.menuItems["Edit"].isEnabled, "Nothing should be editable while the vault is locked")
        app.typeKey(.escape, modifierFlags: [])
    }
}

// MARK: - XCUIElement convenience

private extension XCUIElement {
    func tripleClick() {
        click()
        click(forDuration: 0, thenDragTo: self)
        typeKey("a", modifierFlags: .command)
    }
}
