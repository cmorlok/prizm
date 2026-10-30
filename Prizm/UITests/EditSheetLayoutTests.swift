import XCTest

/// XCUITest: the edit sheet leaves room for the item's fields (fix-edit-sheet-height, task 1.1).
///
/// Runs in the seeded vault with `--ui-test-org-folders`: "Omega Shared" is an organization item
/// with a collection and a folder, so its sheet has the tallest fixed header.
final class EditSheetLayoutTests: PrizmUITestCase {

    func testOrgItemEditSheet_formHasRoom() throws {
        let app = XCUIApplication()
        app.launch(in: UITestLaunch.vault + ["--ui-test-org-folders"])
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")
        app.selectSidebarRow("Work")
        let row = app.element(Fixture.row("omega"))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let edit = app.buttons[AccessibilityID.Edit.editButton]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.click()
        XCTAssertTrue(app.buttons[AccessibilityID.Edit.saveButton].waitForExistence(timeout: 3), "The edit sheet opens")

        let sheet = app.sheets.firstMatch
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(sheet.frame.height, window.frame.height, "The sheet fits the window")
        // The type form is the sheet's lowest scroll view, under the fixed header. Chosen by position,
        // not by hierarchy order.
        let form = sheet.scrollViews.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY }
        let formHeight = form?.frame.height ?? 0
        let windowHeight = window.frame.height
        app.typeKey(.escape, modifierFlags: [])
        guard windowHeight >= 1000 else {
            throw XCTSkip("The window is \(Int(windowHeight)) pt tall; the form check needs at least 1000 pt (form: \(Int(formHeight)) pt)")
        }
        XCTAssertGreaterThanOrEqual(formHeight, 300, "The form shows several fields (was 154 pt)")
    }
}
