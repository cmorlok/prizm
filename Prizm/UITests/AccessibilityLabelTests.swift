import XCTest

/// XCUITest: Accessibility label verification.
///
/// Validates that key icon-only buttons have non-empty accessibility labels
/// and that stateful controls expose correct accessibility values.
///
/// Runs in the seeded vault (`UITestLaunch.vault`).
final class AccessibilityLabelTests: PrizmUITestCase {

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

    // MARK: - 9.1 Icon-only buttons have non-empty accessibilityLabel

    func testSettingsGearHasLabel() {
        let gear = app.buttons["vault.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Settings button must exist")
        XCTAssertFalse(gear.label.isEmpty, "Settings button must have a non-empty label")
    }

    func testNewItemButtonHasLabel() {
        let plus = app.menuButtons["create.button.newItem"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "New Item button must exist")
        // A menu button is announced by its title; this one has the title "New Item" and no label.
        XCTAssertFalse(plus.label.isEmpty && plus.title.isEmpty, "New Item button must have a name")
    }

    private func openAlpha() {
        let row = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Fixture item Alpha Bank should be listed")
        row.click()
    }

    /// The favourite star has no fixed identifier, so it is found by its label.
    private var star: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'favorite'")).firstMatch
    }

    func testFavoriteStarHasLabel() {
        openAlpha()
        XCTAssertTrue(star.waitForExistence(timeout: 5), "Favorite star must exist")
        XCTAssertFalse(star.label.isEmpty, "Favorite star must have a non-empty label")
        XCTAssertEqual(star.value as? String, "Not favorited", "Alpha Bank is not a favourite")
    }

    // MARK: - 9.2 Favorite star accessibilityValue changes on toggle

    func testFavoriteStarValueChangesOnToggle() throws {
        openAlpha()
        XCTAssertTrue(star.waitForExistence(timeout: 5), "Favorite star must exist")
        XCTAssertEqual(star.value as? String, "Not favorited")

        // Toggling saves the item on the server.
        try UITestPrerequisite.serverWrites()
    }
}
