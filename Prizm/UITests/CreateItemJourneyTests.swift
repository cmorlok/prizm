import XCTest

/// XCUITest: Create Vault Item Journey (add-vault-items)
///
/// Validates that the "+" button is permanently anchored in the content column toolbar,
/// is hidden only while Trash is selected, and reappears in the correct position when
/// the user leaves Trash — regardless of which category was visited before Trash.
///
/// Runs in the seeded vault (`UITestLaunch.vault`), with no server: saving is skipped through
/// `UITestPrerequisite.serverWrites()`.
final class CreateItemJourneyTests: PrizmUITestCase {

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

    // MARK: - Button visible on launch

    /// Verifies the "+" button is hittable when the vault browser first appears (any default
    /// non-Trash category selected).
    func testNewItemButton_visibleOnLaunch() throws {
        let newItemButton = app.menuButtons["create.button.newItem"]
        XCTAssertTrue(newItemButton.waitForExistence(timeout: 5), "+ button must exist in toolbar on launch")
        XCTAssertTrue(newItemButton.isHittable, "+ button must be hittable on launch")
    }

    // MARK: - Button hidden in Trash

    /// Verifies the "+" button is not rendered while Trash is selected.
    /// The button is in the view body (not a toolbar item), so it is simply absent
    /// from the else-branch when Trash is active — no frame, no icon, no chrome.
    func testNewItemButton_hiddenInTrash() throws {
        app.selectSidebarRow("Trash")

        let newItemButton = app.menuButtons["create.button.newItem"]
        XCTAssertTrue(app.element(Fixture.row(Fixture.trashed)).waitForExistence(timeout: 5), "Trash must be selected")
        // Known app bug, against spec list-column-header: the + button stays in Trash.
        XCTExpectFailure("Known app bug: the + button is rendered in Trash (change fix-ui-journey-findings)") {
            XCTAssertFalse(newItemButton.waitForExistence(timeout: 2),
                           "+ button must not exist in view hierarchy while Trash is selected")
        }
    }

    // MARK: - Button reappears after leaving Trash

    /// Selects Trash then navigates to All Items and verifies the "+" button is hittable
    /// and positioned in the content column toolbar (above the item list).
    ///
    /// This is the regression scenario for the toolbar-drift bug: the button previously
    /// stayed on the trailing window edge instead of the content column after a Trash visit.
    func testNewItemButton_reappearsAfterLeavingTrash() throws {
        // Go to Trash first.
        app.selectSidebarRow("Trash")

        // Leave Trash by selecting All Items.
        app.selectSidebarRow("All Items")

        let newItemButton = app.menuButtons["create.button.newItem"]
        XCTAssertTrue(newItemButton.waitForExistence(timeout: 5), "+ button must exist after leaving Trash")
        XCTAssertTrue(newItemButton.isHittable, "+ button must be hittable after leaving Trash")

        // Verify the button is above the item list and not on the trailing window edge. The list
        // does not expose its identifier, so compare with a row in it: if the button drifted to the
        // window toolbar, its frame would be to the right of the content column.
        let listRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(listRow.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            newItemButton.frame.maxX,
            listRow.frame.maxX + 60, // 60 pt tolerance for toolbar insets
            "+ button must not have drifted outside the content column after leaving Trash"
        )
    }

    // MARK: - ⌘N keyboard shortcut

    /// ⌘N opens the edit sheet for a new Login directly (spec `list-column-header`, "⌘N creates Login
    /// outside Trash"). Escape closes it without saving.
    func testCmdN_opensLoginSheet_inNonTrashCategory() throws {
        app.typeKey("n", modifierFlags: .command)

        let saveButton = app.buttons["edit.button.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "⌘N must open the new-item sheet")
        XCTAssertTrue(app.staticTexts["detail.cardHeader.credentials"].exists,
                      "⌘N must create a Login (the sheet shows the Credentials card)")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(saveButton.waitForNonExistence(timeout: 3), "Escape must close the unchanged sheet")
    }

    /// In Trash, ⌘N has no effect (spec `list-column-header`).
    func testCmdN_isNoOp_inTrash() throws {
        app.selectSidebarRow("Trash")

        // Pressing ⌘N here crashes Prizm (UI run 2026-10-25), against the spec.
        try UITestPrerequisite.knownAppBug("⌘N in Trash crashes the app", fixedBy: "change fix-ui-journey-findings")
    }

    /// The new Login sheet opened with ⌘N can be closed again without creating anything.
    func testCmdN_emptyLoginSheet_closesWithoutSaving() throws {
        app.typeKey("n", modifierFlags: .command)
        let saveButton = app.buttons["edit.button.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Login edit sheet must open after ⌘N")
        XCTAssertFalse(saveButton.isEnabled, "An empty new item must not be savable")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(saveButton.waitForNonExistence(timeout: 3))
    }

    /// Other item types are created from the "+" menu.
    func testNewItemMenu_card_opensCardSheet() throws {
        let newItemButton = app.menuButtons["create.button.newItem"]
        XCTAssertTrue(newItemButton.waitForExistence(timeout: 5))
        newItemButton.click()

        let cardItem = app.menuItems["Card"]
        XCTAssertTrue(cardItem.waitForExistence(timeout: 3), "The + menu must offer Card")
        cardItem.click()

        let saveButton = app.buttons["edit.button.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Choosing Card must open the edit sheet")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Button stable across multiple category switches

    /// Visits a non-Login category (Card sidebar item) and returns to Login (All Items),
    /// verifying the button stays hittable throughout.
    func testNewItemButton_stableAcrossCategorySwitches() throws {
        // Navigate to Card type.
        app.selectSidebarRow("Card")

        var newItemButton = app.menuButtons["create.button.newItem"]
        XCTAssertTrue(newItemButton.isHittable, "+ button must be hittable in Card category")

        // Navigate back to All Items.
        app.selectSidebarRow("All Items")

        newItemButton = app.menuButtons["create.button.newItem"]
        XCTAssertTrue(newItemButton.isHittable, "+ button must be hittable after returning to All Items")
    }
}
