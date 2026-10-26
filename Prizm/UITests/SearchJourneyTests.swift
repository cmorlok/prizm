import XCTest

/// XCUITest: US4 Search Journey
///
/// Validates the toolbar search on the seeded test vault (`UITestLaunch.vault`, see `Fixture`):
/// filtering, clearing, keeping the term across categories and the no-match empty state.
final class SearchJourneyTests: PrizmUITestCase {

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

    private var searchField: XCUIElement { app.searchField() }

    private var rowCount: Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'itemList.row.'")).count
    }

    private func search(_ text: String) {
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field should exist")
        searchField.click()
        searchField.typeText(text)
    }

    // MARK: - US4 Scenario 1: Search bar exists and is accessible

    func testSearchBarExists() {
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search bar should exist in the toolbar")
    }

    // MARK: - US4 Scenario 2: Typing filters items in real time

    func testTypingFiltersItems() {
        XCTAssertTrue(app.element(Fixture.row("beta")).waitForExistence(timeout: 5))
        search("Alpha")

        XCTAssertTrue(app.element(Fixture.row(Fixture.alpha)).waitForExistence(timeout: 5),
                      "The matching item should stay listed")
        XCTAssertTrue(app.element(Fixture.row("beta")).waitForNonExistence(timeout: 5),
                      "Items that don't match should disappear")
    }

    // MARK: - US4 Scenario 3: Clearing search restores full list

    func testClearingSearchRestoresFullList() {
        XCTAssertTrue(app.element(Fixture.row(Fixture.alpha)).waitForExistence(timeout: 5))
        let itemsBefore = rowCount

        search("Alpha")
        XCTAssertTrue(app.element(Fixture.row("beta")).waitForNonExistence(timeout: 5))

        // ⌘A then Delete clears the field.
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])

        XCTAssertTrue(app.element(Fixture.row("beta")).waitForExistence(timeout: 5),
                      "Clearing the search should bring the other items back")
        XCTAssertEqual(rowCount, itemsBefore, "Clearing the search should restore the full item list")
    }

    // MARK: - US4 Scenario 4: Search term preserved on category switch

    func testSearchTermPreservedOnCategorySwitch() {
        search("Alpha")

        let favorites = app.sidebarRow("Favorites")
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        favorites.click()

        XCTAssertEqual(searchField.value as? String, "Alpha",
                       "Search term should be preserved after a category switch")
    }

    // MARK: - US4 Scenario 5: Empty state on no match

    func testEmptyStateOnNoMatch() {
        search("zzz_no_item_will_ever_match_this_zzz")
        XCTAssertTrue(app.element(AccessibilityID.ItemList.emptyState).waitForExistence(timeout: 5),
                      "Empty state should appear when no items match the search")
    }

    // MARK: - US4 Scenario 6: Search performance (SC-008)

    func testSearchPerformance() {
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        measure {
            searchField.typeText("a")
        }
    }
}
