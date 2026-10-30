import XCTest

/// XCUITest: the collection checkboxes of an organization item's edit sheet
/// (fix-collection-assignment, design D3 and D4).
///
/// Runs in the seeded vault with `--ui-test-org-folders` ("Omega Shared" in "Shared" and the
/// read-only "View Only"; "Team" is writable). Saving needs a server: that part is skipped through
/// `UITestPrerequisite.serverWrites()`.
final class CollectionPickerJourneyTests: PrizmUITestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch(in: UITestLaunch.vault + ["--ui-test-org-folders"])
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func openOmegaEditSheet() {
        app.selectSidebarRow("Work")
        let row = app.element(Fixture.row("omega"))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()
        XCTAssertTrue(app.buttons["edit.button.save"].waitForExistence(timeout: 3), "The edit sheet opens")
    }

    func testCheckboxes_showAssignments_keepReadOnly_andRequireOne() throws {
        openOmegaEditSheet()

        let shared = app.checkBoxes["edit.collection.col-shared"]
        let team = app.checkBoxes["edit.collection.col-team"]
        let viewOnly = app.checkBoxes["edit.collection.col-view"]
        XCTAssertTrue(shared.waitForExistence(timeout: 3))
        XCTAssertEqual(shared.label, "Shared", "VoiceOver reads the collection name")
        XCTAssertEqual(shared.value as? Int, 1, "The item's collection is checked")
        XCTAssertEqual(team.value as? Int, 0)
        XCTAssertEqual(viewOnly.value as? Int, 1, "The read-only assignment is shown checked")
        XCTAssertFalse(viewOnly.isEnabled, "and cannot be unchecked")
        // The note is part of the checkbox's label view, so XCUITest exposes no separate text for it
        // (VoiceOver reads it through the hint); its second line makes the row taller.
        XCTAssertGreaterThan(viewOnly.frame.height, shared.frame.height, "The read-only note is shown under the name")

        team.click()
        XCTAssertEqual(team.value as? Int, 1, "A second collection can be checked")
        XCTAssertEqual(shared.value as? Int, 1, "without unchecking the first")

        app.typeKey(.escape, modifierFlags: [])
        // Discarding asks for confirmation once something changed.
        let discard = app.windows.buttons["Discard Changes"].firstMatch
        if discard.waitForExistence(timeout: 2) { discard.click() }

        try UITestPrerequisite.serverWrites()
    }

    func testUncheckingTheWritableOne_keepsTheReadOnlyAssignment_andSaveEnabled() throws {
        openOmegaEditSheet()

        let shared = app.checkBoxes["edit.collection.col-shared"]
        XCTAssertTrue(shared.waitForExistence(timeout: 3))
        shared.click()

        // "View Only" is still assigned, so the item keeps a collection and Save stays enabled.
        XCTAssertFalse(app.staticTexts["edit.collectionHint"].exists)
        XCTAssertTrue(app.buttons["edit.button.save"].isEnabled)
    }
}
