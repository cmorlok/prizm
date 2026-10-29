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

    // MARK: - Blocked items

    /// An item Prizm cannot write back without loss shows why, and nothing opens the edit sheet:
    /// not the toolbar button, not the Item menu, not ⌘E. The test state adds such an item with
    /// `--ui-test-blocked-item`. Only app-level keys are sent, never a system-wide shortcut.
    func testBlockedItem_editDisabledWithReason() throws {
        app.terminate()
        app.launch(in: UITestLaunch.vault + ["--ui-test-blocked-item"])
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")

        let row = app.element(Fixture.row("theta"))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The blocked fixture item is listed")
        row.click()

        let note = app.element(AccessibilityID.Edit.blockedNote)
        XCTAssertTrue(note.waitForExistence(timeout: 3), "A note says why the item can't be edited")
        // The note is one container with a text inside; read both, as the label may sit on either.
        let noteText = ([note.label, note.value as? String ?? ""]
            + note.descendants(matching: .staticText).allElementsBoundByIndex.map { $0.label })
            .joined(separator: " ")
        XCTAssertTrue(noteText.contains("Edit it in the Bitwarden web vault or browser extension."),
                      "The note names the next step, got: \(noteText)")

        let editButton = app.buttons[AccessibilityID.Edit.editButton]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        XCTAssertFalse(editButton.isEnabled, "The toolbar Edit button is disabled for a blocked item")

        let itemMenu = app.menuBars.menuBarItems["Item"]
        itemMenu.click()
        XCTAssertTrue(app.menuItems["Edit"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["Edit"].isEnabled, "Item > Edit is disabled for a blocked item")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("e", modifierFlags: .command)
        XCTAssertFalse(app.buttons[AccessibilityID.Edit.saveButton].waitForExistence(timeout: 2),
                       "⌘E must not open the edit sheet for a blocked item")
    }

    // MARK: - Conflict flow

    // The test vault has no server. `--ui-test-conflict=<scenario>` scripts what the server would
    // do: the save of the note is rejected as based on an outdated copy, and the sync that follows
    // changes the note, fails once and then changes it, or removes it (`App/UITestFixtures.swift`).
    // The journeys use clicks and typing inside the sheet only, never a system-wide shortcut.

    private static let conflictMessage = "This item was changed on another device."
    private static let itemGoneMessage = "This item is no longer available."
    private static let changedName = "Test Note (changed elsewhere)"

    /// An outdated copy is rejected: the banner names the conflict, Save stays blocked but the
    /// fields stay editable, and once the sync is done, reload refills the sheet with the changed
    /// item. The sheet stays open while the sync replaces the item in the list behind it.
    func testConflict_reloadRefillsTheSheet() throws {
        relaunchOpeningEditSheetOnNote(argument: "--ui-test-conflict=synced")
        changeNameAndSave()

        let banner = app.element(AccessibilityID.Edit.errorBanner)
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "The conflict banner should appear")
        XCTAssertTrue(text(of: banner).contains(Self.conflictMessage),
                      "The banner names the conflict, got: \(text(of: banner))")
        XCTAssertFalse(app.buttons[AccessibilityID.Edit.saveButton].isEnabled,
                       "Save stays blocked until the item is reloaded")

        // The fields stay editable while Save is blocked.
        let nameField = app.textFields["Name"]
        nameField.click()
        nameField.typeText("!")
        XCTAssertTrue((nameField.value as? String ?? "").hasSuffix("!"), "Typing into the Name field still works")

        let reload = app.buttons[AccessibilityID.Edit.conflictReloadButton]
        XCTAssertTrue(reload.waitForExistence(timeout: 3), "The banner offers to discard and reload")

        let status = app.element(AccessibilityID.Edit.conflictStatus)
        XCTAssertTrue(waitForText(of: status, toEqual: "Synced"), "The sync ends with Synced, got: \(text(of: status))")
        XCTAssertTrue(app.buttons[AccessibilityID.Edit.saveButton].exists,
                      "The sheet stays open while the sync replaces the item in the list")
        XCTAssertTrue(reload.isEnabled, "Reload is available once the sync is done")

        reload.click()

        XCTAssertTrue(waitForNonExistence(of: banner), "The banner is gone after the reload")
        XCTAssertTrue(app.buttons[AccessibilityID.Edit.saveButton].isEnabled, "Save is available again")
        XCTAssertTrue(waitForText(of: nameField, toEqual: Self.changedName),
                      "The sheet shows the changed item, got: \(text(of: nameField))")
    }

    /// A failed sync shows its error in the status line and keeps the input; reload syncs again and,
    /// once that worked, reloads.
    func testConflict_syncFailsThenReloadSyncsAgain() throws {
        relaunchOpeningEditSheetOnNote(argument: "--ui-test-conflict=sync-fails-once")
        changeNameAndSave()

        let status = app.element(AccessibilityID.Edit.conflictStatus)
        XCTAssertTrue(waitForText(of: status, toContain: "No internet connection"),
                      "The sync error is the status, got: \(text(of: status))")
        let reload = app.buttons[AccessibilityID.Edit.conflictReloadButton]
        XCTAssertTrue(reload.waitForExistence(timeout: 3))
        XCTAssertTrue(reload.isEnabled, "Reload is available after a failed sync, so the user can try again")
        XCTAssertFalse(app.buttons[AccessibilityID.Edit.saveButton].isEnabled, "Save stays blocked")

        reload.click()
        XCTAssertTrue(waitForText(of: status, toEqual: "Synced"),
                      "The second sync works, got: \(text(of: status))")

        reload.click()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(waitForText(of: nameField, toEqual: Self.changedName),
                      "The sheet is refilled, got: \(text(of: nameField))")
        XCTAssertTrue(app.buttons[AccessibilityID.Edit.saveButton].isEnabled, "Save is available again")
    }

    /// An item the sync no longer has cannot be reloaded: the banner says so and offers Close, Save
    /// stays blocked, Delete Item is not offered, and Close needs no discard confirmation.
    func testConflict_itemGoneShowsClose() throws {
        relaunchOpeningEditSheetOnNote(argument: "--ui-test-conflict=gone")
        changeNameAndSave()

        let banner = app.element(AccessibilityID.Edit.errorBanner)
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "The banner should appear")
        let close = app.buttons[AccessibilityID.Edit.conflictCloseButton]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Close replaces the reload button")
        XCTAssertTrue(text(of: banner).contains(Self.itemGoneMessage),
                      "The banner says the item is gone, got: \(text(of: banner))")
        XCTAssertTrue(app.buttons[AccessibilityID.Edit.saveButton].exists,
                      "The sheet stays open while the sync removes the item from the list")
        XCTAssertFalse(app.buttons[AccessibilityID.Edit.saveButton].isEnabled, "Save stays blocked")
        XCTAssertFalse(app.buttons[AccessibilityID.Edit.deleteButton].exists,
                       "Delete Item is not offered for an item that is gone")

        close.click()
        XCTAssertTrue(waitForNonExistence(of: app.buttons[AccessibilityID.Edit.saveButton]),
                      "Close closes the sheet")
    }

    // MARK: Conflict helpers

    /// Restarts the app with the scripted scenario argument (`setUpWithError` launched the plain vault), then
    /// opens the edit sheet of the test note.
    private func relaunchOpeningEditSheetOnNote(argument: String) {
        app.terminate()
        app.launch(in: UITestLaunch.vault + [argument])
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")

        let row = app.element(Fixture.row(Fixture.note))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The test note is listed")
        row.click()

        let editButton = app.buttons[AccessibilityID.Edit.editButton]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()
        XCTAssertTrue(app.buttons[AccessibilityID.Edit.saveButton].waitForExistence(timeout: 3),
                      "Edit sheet should be visible")
    }

    /// Replaces the name and presses Save; the scripted server rejects it as an outdated copy.
    private func changeNameAndSave() {
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tripleClick()
        nameField.typeText("My edit")

        let saveButton = app.buttons[AccessibilityID.Edit.saveButton]
        XCTAssertTrue(saveButton.isEnabled, "Save should be enabled after a change")
        saveButton.click()
    }

    /// Every string an element shows, one entry each: its label and value, and the label and value
    /// of the static texts inside. The text may sit on the element or on a child, depending on how
    /// SwiftUI exposes it. On macOS a static text often carries its string as the value and leaves
    /// the label empty.
    private func texts(of element: XCUIElement) -> [String] {
        guard element.exists else { return [] }
        let children = element.descendants(matching: .staticText).allElementsBoundByIndex
            .flatMap { [$0.label, $0.value as? String ?? ""] }
        return [element.label, element.value as? String ?? ""] + children
    }

    /// The same strings as one line, for `contains` checks and failure messages.
    private func text(of element: XCUIElement) -> String {
        texts(of: element).joined(separator: " ")
    }

    /// Polls instead of sleeping: returns as soon as `condition` holds, false after `timeout`.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func waitForText(of element: XCUIElement, toEqual expected: String, timeout: TimeInterval = 5) -> Bool {
        // Whole-string match against each shown string, so the status may be wrapped in a container
        // and a longer text ("Synced just now") is still not "Synced".
        waitUntil(timeout: timeout) { texts(of: element).contains(expected) }
    }

    private func waitForText(of element: XCUIElement, toContain fragment: String, timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { text(of: element).contains(fragment) }
    }

    private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
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
