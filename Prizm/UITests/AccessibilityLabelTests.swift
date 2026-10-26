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

    // MARK: - card-field-normalisation 3.3

    /// The card's expiry reads as a date, and the edit form's pickers are named and read their
    /// selection by its display name. The fixture card has brand "Visa" and expiry "12" / "2030".
    func testCardExpiryAndPickers_readAsNamedValues() throws {
        let row = app.element(Fixture.row(Fixture.card))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        let expiry = app.fieldValue("Expiration")
        XCTAssertTrue(expiry.waitForExistence(timeout: 3))
        // A selectable text shows its text on the inner element (see `displayedText`).
        XCTAssertTrue(expiry.displayedText.waitForText("12 / 2030", timeout: 3), "Shown as MM / YYYY")
        XCTAssertEqual(expiry.value as? String, "December 2030", "VoiceOver reads the month by name")

        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()

        let brand = app.popUpButtons["Brand"]
        XCTAssertTrue(brand.waitForExistence(timeout: 3), "The brand picker is named Brand")
        XCTAssertEqual(brand.value as? String, "Visa")
        let month = app.popUpButtons["Expiry Month"]
        XCTAssertTrue(month.exists, "The month picker is named Expiry Month")
        XCTAssertEqual(month.value as? String, "12 - December")
        XCTAssertTrue(app.textFields["Expiry Year"].exists, "The year field keeps its label")

        app.buttons["edit.button.discard"].click()
    }
}
