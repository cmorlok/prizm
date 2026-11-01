import XCTest

/// XCUITest: archived items (openspec change `archived-items`, task 5.1).
///
/// Runs in the seeded vault with `--ui-test-archived`, which adds one archived login
/// (`UITestFixtures.archivedItem`); every seeded record carries the archive key, so the actions are
/// offered. Archiving and unarchiving need server writes and are checked on the rig.
final class ArchivedItemsJourneyTests: PrizmUITestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch(in: UITestLaunch.vault + ["--ui-test-archived"])
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testArchivedItem_onlyInArchive_withBadgeAndUnarchive() throws {
        XCTAssertFalse(app.element(Fixture.row("archived1")).waitForExistence(timeout: 2),
                       "The archived login is not in All Items")

        app.selectSidebarRow("Archive")
        let row = app.element(Fixture.row("archived1"))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Archive lists the archived login")
        row.click()

        let badge = app.element(AccessibilityID.Archive.badge)
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "The detail shows the Archived badge")
        let toolbar = app.buttons[AccessibilityID.Archive.toolbarButton]
        XCTAssertTrue(toolbar.exists)
        XCTAssertEqual(toolbar.label, "Unarchive")
    }

    func testActiveItem_offersArchive() throws {
        let row = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let toolbar = app.buttons[AccessibilityID.Archive.toolbarButton]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), "Archive is offered on an active item")
        XCTAssertEqual(toolbar.label, "Archive")
        XCTAssertFalse(app.element(AccessibilityID.Archive.badge).exists)
    }
}
