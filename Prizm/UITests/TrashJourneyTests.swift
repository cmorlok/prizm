import XCTest

/// XCUITest: Trash Journey (delete-restore-items)
///
/// Validates the full delete → trash → restore flow and the permanent delete + empty-trash
/// flows through the UI.
///
/// Runs on the seeded test vault (`UITestLaunch.vault`), which has active items and one trashed
/// item. Menus and confirmations are checked locally; the actions themselves are server calls and
/// are reported as skipped at that step.
final class TrashJourneyTests: PrizmUITestCase {

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

    private func openTrash() {
        let trash = app.sidebarRow("Trash")
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.click()
    }

    // MARK: - 7.1: Soft-delete from list, verify item appears in Trash

    /// The context menu offers Delete and asks for confirmation. Confirming moves the item to the
    /// trash on the server.
    func testSoftDelete_fromListContextMenu_itemAppearsInTrash() throws {
        let row = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Fixture item Alpha Bank should be listed")

        row.rightClick()
        // The context menu's "Delete" also exists in the Edit menu of the menu bar; take the
        // context menu's.
        let deleteMenuItem = app.windows.menuItems["Delete"].firstMatch
        XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 3))
        deleteMenuItem.click()

        XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 3),
                      "Deleting should ask for confirmation")

        try UITestPrerequisite.serverWrites()
    }

    // MARK: - 7.2: Restore from Trash, verify item reappears in active vault

    /// The trash lists the trashed item, and its context menu offers Restore. Restoring is a
    /// server call.
    func testRestore_fromTrashContextMenu_itemReappearsInActiveVault() throws {
        openTrash()
        let row = app.element(Fixture.row(Fixture.trashed))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The trash should list the trashed fixture item")
        XCTAssertFalse(app.element(Fixture.row(Fixture.alpha)).exists, "The trash should not list active items")

        row.rightClick()
        XCTAssertTrue(app.menuItems["Restore"].waitForExistence(timeout: 3),
                      "The trash context menu should offer Restore")
        app.typeKey(.escape, modifierFlags: [])

        try UITestPrerequisite.serverWrites()
    }

    // MARK: - 7.3: Permanently delete a trashed item

    /// The trash context menu offers Delete Permanently and asks for confirmation. Confirming is a
    /// server call.
    func testPermanentDelete_fromTrashContextMenu_itemDisappears() throws {
        openTrash()
        let row = app.element(Fixture.row(Fixture.trashed))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The trash should list the trashed fixture item")

        row.rightClick()
        let permanentDeleteMenuItem = app.menuItems["Delete Permanently"]
        XCTAssertTrue(permanentDeleteMenuItem.waitForExistence(timeout: 3))
        permanentDeleteMenuItem.click()

        XCTAssertTrue(app.buttons["Delete Permanently"].waitForExistence(timeout: 3),
                      "Deleting permanently should ask for confirmation")

        try UITestPrerequisite.serverWrites()
    }

    // MARK: - Empty Trash (fix-empty-trash)

    /// Empty Trash syncs before it asks. The test vault has no server, so the refresh fails: the
    /// user sees the D2 message and nothing is deleted.
    func testEmptyTrash_refreshFails_deletesNothing() throws {
        openTrash()
        XCTAssertTrue(app.element(Fixture.row(Fixture.trashed)).waitForExistence(timeout: 5))
        let button = app.buttons[AccessibilityID.Trash.emptyTrashButton]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Trash must offer Empty Trash")
        XCTAssertTrue(button.isEnabled, "Enabled while Trash has items")

        button.click()

        let message = app.staticTexts["Couldn't refresh the trash. Try again."]
        XCTAssertTrue(message.waitForExistence(timeout: 15), "The refresh error must be shown")
        // The Touch Bar repeats the alert's buttons; only the alert's own "OK" can be clicked.
        let sheetOK = app.sheets.buttons["OK"].firstMatch
        (sheetOK.exists ? sheetOK : app.dialogs.buttons["OK"].firstMatch).click()
        XCTAssertTrue(app.element(Fixture.row(Fixture.trashed)).exists, "Nothing may be deleted")
    }

    /// The button is not offered outside Trash.
    func testEmptyTrash_notOfferedOutsideTrash() throws {
        XCTAssertFalse(app.buttons[AccessibilityID.Trash.emptyTrashButton].waitForExistence(timeout: 2))
    }
}
