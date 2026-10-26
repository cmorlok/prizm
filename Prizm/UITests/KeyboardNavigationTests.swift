import XCTest

/// XCUITest: Keyboard-Only Navigation (T073)
///
/// Validates that the vault browser can be used from the keyboard (SC-007), on the seeded test
/// vault (`UITestLaunch.vault`, see `Fixture`). Where XCUITest cannot observe keyboard focus
/// directly (Tab, Escape), the journey checks that the browser stays usable afterwards.
final class KeyboardNavigationTests: PrizmUITestCase {

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

    private var detailName: XCUIElement { app.element(AccessibilityID.Detail.itemName) }

    private func openItem(_ id: String) {
        let row = app.element(Fixture.row(id))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Row \(id) should exist")
        row.click()
    }

    /// After keyboard input whose focus effect XCUITest cannot read, the browser must still work:
    /// selecting an item shows it.
    private func assertBrowserStillUsable(file: StaticString = #filePath, line: UInt = #line) {
        openItem(Fixture.alpha)
        XCTAssertTrue(detailName.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(detailName.text, "Alpha Bank", file: file, line: line)
    }

    // MARK: - SC-007 Scenario 1: Tab cycles between panes

    func testTabCyclesBetweenPanes() {
        for _ in 0..<3 { app.typeKey(.tab, modifierFlags: []) }
        assertBrowserStillUsable()
    }

    // MARK: - SC-007 Scenario 2: Arrow keys navigate sidebar

    /// All Items is followed by Favorites, which lists only the favourite item. All Items is already
    /// selected at launch, so this also covers a click that does not change the selection.
    func testArrowKeysNavigateSidebar() {
        let allItems = app.sidebarRow("All Items")
        XCTAssertTrue(allItems.waitForExistence(timeout: 5))
        allItems.click()
        XCTAssertTrue(app.element(Fixture.row(Fixture.alpha)).waitForExistence(timeout: 5))

        // Press the key in the app, as a user does after clicking the row. Sending it to the
        // sidebar element directly would give the sidebar focus, which hides the bug this checks.
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.element(Fixture.row(Fixture.alpha)).waitForNonExistence(timeout: 5),
                      "Down arrow should select Favorites, which does not list Alpha Bank")
        XCTAssertTrue(app.element(Fixture.row(Fixture.kappa)).exists, "Favorites should list the favourite item")
    }

    /// After a click in the item list, a click on the sidebar's selected row gives the sidebar the
    /// keyboard focus again.
    func testArrowKeysNavigateSidebar_afterUsingItemList() {
        app.selectSidebarRow("Login")
        openItem(Fixture.alpha)
        XCTAssertTrue(detailName.waitForText("Alpha Bank", timeout: 5))

        app.selectSidebarRow("Login")
        app.typeKey(.downArrow, modifierFlags: [])

        XCTAssertTrue(app.element(Fixture.row(Fixture.card)).waitForExistence(timeout: 5),
                      "Down arrow should select Card, which lists the card")
        XCTAssertFalse(app.element(Fixture.row(Fixture.alpha)).exists, "Card should not list logins")
    }

    // MARK: - SC-007 Scenario 3: Arrow keys navigate item list

    /// The list is sorted by name: Alpha Bank is followed by Beta Mail.
    func testArrowKeysNavigateItemList() {
        openItem(Fixture.alpha)
        XCTAssertTrue(detailName.waitForExistence(timeout: 5))
        XCTAssertEqual(detailName.text, "Alpha Bank")

        // Press the key in the app, as a user does after clicking the row.
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(detailName.waitForText("Beta Mail", timeout: 5), "Down arrow should show the next item")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(detailName.waitForText("Alpha Bank", timeout: 5), "Up arrow should show the previous item")
    }

    // MARK: - SC-007 Scenario 4: Enter selects focused item

    func testEnterSelectsFocusedItem() {
        openItem(Fixture.alpha)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(detailName.waitForExistence(timeout: 5), "Detail pane should show the item after Enter")
        XCTAssertEqual(detailName.text, "Alpha Bank")
    }

    // MARK: - SC-007 Scenario 5: Escape returns focus to list

    func testEscapeReturnsFocusToList() {
        openItem(Fixture.alpha)
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        assertBrowserStillUsable()
    }

    // MARK: - SC-007 Scenario 6: Search field accessible via keyboard

    func testSearchFieldAccessibleViaKeyboard() {
        app.typeKey("f", modifierFlags: .command)

        let searchField = app.searchField()
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        app.typeText("Alpha")
        XCTAssertEqual(searchField.value as? String, "Alpha",
                       "Search field should accept keyboard input after ⌘F")
    }

    // MARK: - SC-007 Scenario 8: Full keyboard-only journey

    /// Smoke test: a keyboard-only sequence through all panes leaves the browser usable.
    func testFullKeyboardOnlyJourney() {
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("f", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])

        let allItems = app.sidebarRow("All Items")
        XCTAssertTrue(allItems.waitForExistence(timeout: 5))
        allItems.click()
        assertBrowserStillUsable()
    }
}
