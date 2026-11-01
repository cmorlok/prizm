import XCTest

/// XCUITest: the "No Folder" and "My Vault" views (openspec change `vault-browsing-parity`, task 2.3).
///
/// Runs with `--ui-test-org-folders` (folder "Work" holding the organization note "Omega Shared")
/// and `--ui-test-personal-in-folder` (the personal note "Sigma Personal", also in "Work").
final class BrowsingFiltersJourneyTests: PrizmUITestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch(in: UITestLaunch.vault + ["--ui-test-org-folders", "--ui-test-personal-in-folder"])
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testNoFolder_listsItemsWithoutAFolder() {
        app.selectSidebarRow("No Folder")
        XCTAssertTrue(app.element(Fixture.row(Fixture.alpha)).waitForExistence(timeout: 5), "A login without a folder")
        XCTAssertFalse(app.element(Fixture.row("omega")).exists, "The org note in Work is not listed")
        XCTAssertFalse(app.element(Fixture.row("sigma")).exists, "The personal note in Work is not listed")
    }

    func testMyVault_listsPersonalItemsOnly() {
        app.selectSidebarRow("My Vault")
        XCTAssertTrue(app.element(Fixture.row("sigma")).waitForExistence(timeout: 5), "The personal note in Work")
        XCTAssertTrue(app.element(Fixture.row(Fixture.alpha)).exists, "A personal login")
        XCTAssertFalse(app.element(Fixture.row("omega")).exists, "The organization note is not listed")
    }
}
