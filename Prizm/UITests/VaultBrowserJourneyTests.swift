import XCTest

/// XCUITest: US3 Vault Browser Journey (T062)
///
/// Validates the three-pane vault browser: sidebar navigation, item list selection, detail
/// rendering, field reveal/mask and locking. Runs on the seeded test vault (`UITestLaunch.vault`,
/// see `Fixture`), so every step asserts against known data.
final class VaultBrowserJourneyTests: PrizmUITestCase {

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

    private func select(_ title: String) {
        app.selectSidebarRow(title)
    }

    private func openItem(_ id: String) {
        let row = app.element(Fixture.row(id))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Row \(id) should exist")
        row.click()
    }

    // MARK: - US3 Scenario 1: Three-pane layout visible

    func testThreePaneLayoutVisible() {
        XCTAssertTrue(app.sidebarRow("All Items").waitForExistence(timeout: 5),
                      "All Items sidebar row should exist")
        XCTAssertTrue(app.element(Fixture.row(Fixture.alpha)).waitForExistence(timeout: 5),
                      "Item list should show the vault items")
        XCTAssertTrue(app.element("detail.empty").waitForExistence(timeout: 5),
                      "Detail pane should show its empty state")
    }

    // MARK: - US3 Scenario 2: Sidebar navigation filters items

    func testSidebarNavigationFiltersItems() {
        select("Favorites")
        XCTAssertTrue(app.element(Fixture.row(Fixture.kappa)).waitForExistence(timeout: 5),
                      "Favorites should list the favourite item")
        XCTAssertFalse(app.element(Fixture.row(Fixture.alpha)).exists,
                       "Favorites should not list non-favourite items")

        select("Card")
        XCTAssertTrue(app.element(Fixture.row(Fixture.card)).waitForExistence(timeout: 5),
                      "Card category should list the card")
        XCTAssertFalse(app.element(Fixture.row(Fixture.alpha)).exists,
                       "Card category should not list logins")
    }

    // MARK: - US3 Scenario 3: Selecting an item shows detail

    func testSelectingItemShowsDetail() {
        openItem(Fixture.alpha)
        let itemName = app.element("detail.name")
        XCTAssertTrue(itemName.waitForExistence(timeout: 5), "Detail pane should show the item name")
        XCTAssertEqual(itemName.text, "Alpha Bank")
    }

    // MARK: - US3 Scenario 4: Empty state when no item selected

    func testEmptyStateWhenNoItemSelected() {
        XCTAssertTrue(app.element("detail.empty").waitForExistence(timeout: 5),
                      "Detail empty state should be visible before anything is selected")
    }

    // MARK: - US3 Scenario 5: Password field shows masked dots

    /// Verifies that password fields display exactly 8 dots when masked (FR-026).
    func testPasswordFieldShowsMaskedDots() {
        select("Login")
        openItem(Fixture.alpha)

        let maskedValue = app.fieldValue("Password")
        XCTAssertTrue(maskedValue.waitForExistence(timeout: 5))
        XCTAssertEqual(maskedValue.text, "••••••••", "Masked password should show 8 dots")
    }

    // MARK: - US3 Scenario 6: Reveal toggle shows plaintext

    /// Verifies the reveal button shows the plaintext value and masks it again (FR-026, FR-027).
    func testRevealToggleShowsPlaintext() {
        select("Login")
        openItem(Fixture.alpha)

        let revealButton = app.revealButton("Password")
        let maskedValue = app.fieldValue("Password").displayedText
        XCTAssertTrue(revealButton.waitForExistence(timeout: 5))
        XCTAssertEqual(maskedValue.text, "••••••••")

        revealButton.click()
        XCTAssertTrue(maskedValue.waitForText(Fixture.password(of: Fixture.alpha), timeout: 3),
                      "Value should be revealed")
        // What VoiceOver reads: before fix-ui-journey-findings, it read "bullet bullet …" here.
        XCTAssertEqual(app.fieldValue("Password").text, Fixture.password(of: Fixture.alpha),
                       "Accessibility should expose the revealed value")

        revealButton.click()
        XCTAssertTrue(maskedValue.waitForText("••••••••", timeout: 3), "Value should be masked after the second toggle")
        XCTAssertEqual(app.fieldValue("Password").text, "••••••••", "VoiceOver reads the mask again after Hide")
    }

    // MARK: - Field values follow the selected item for VoiceOver

    /// The detail pane reuses its rows when another item is selected; what VoiceOver reads must
    /// follow (fix-ui-journey-findings).
    func testFieldValuesFollowItemChange() {
        openItem(Fixture.alpha)
        XCTAssertTrue(app.fieldValue("Username").waitForText("user-alpha", timeout: 5))

        openItem(Fixture.gamma)
        XCTAssertTrue(app.fieldValue("Username").displayedText.waitForText("user-gamma", timeout: 5),
                      "The second item's username should be shown")
        XCTAssertEqual(app.fieldValue("Username").text, "user-gamma",
                       "Accessibility should expose the second item's username")
    }

    /// The Website row is reused when another item is selected; its accessibility value must follow
    /// (fix-selectable-text-voiceover).
    func testWebsiteValueFollowsItemChange() {
        openItem(Fixture.gamma)
        XCTAssertTrue(app.fieldValue("Website").waitForText("file:///Applications/Calculator.app", timeout: 5))

        openItem(Fixture.kappa)
        XCTAssertTrue(app.fieldValue("Website").displayedText.waitForText(Fixture.kappaWebsite, timeout: 5),
                      "The second item's website should be shown")
        XCTAssertEqual(app.fieldValue("Website").text, Fixture.kappaWebsite,
                       "Accessibility should expose the second item's website")
    }

    // MARK: - What VoiceOver reads by text range (fix-selectable-text-voiceover)

    /// A selectable text kept the text it was created with in its character data, which VoiceOver
    /// also reads, after another item was selected.
    func testFieldTextsByRangeFollowItemChange() throws {
        try XCTSkipUnless(AccessibilityTextProbe.isAvailable, AccessibilityTextProbe.unavailableMessage)
        openItem(Fixture.gamma)
        XCTAssertTrue(app.fieldValue("Website").waitForText("file:///Applications/Calculator.app", timeout: 5))

        openItem(Fixture.kappa)
        XCTAssertTrue(app.fieldValue("Website").displayedText.waitForText(Fixture.kappaWebsite, timeout: 5))
        XCTAssertTrue(app.fieldValue("Username").displayedText.waitForText("user-kappa", timeout: 5))
        AccessibilityTextProbe.assertTexts(of: app.fieldValue("Website"), equal: Fixture.kappaWebsite)
        AccessibilityTextProbe.assertTexts(of: app.fieldValue("Username"), equal: "user-kappa")
    }

    /// The masked field was created with the mask, so its character data kept the mask after
    /// Reveal; after Hide the password must not remain there.
    func testRevealedPasswordTextByRange() throws {
        try XCTSkipUnless(AccessibilityTextProbe.isAvailable, AccessibilityTextProbe.unavailableMessage)
        openItem(Fixture.alpha)
        let revealButton = app.revealButton("Password")
        XCTAssertTrue(revealButton.waitForExistence(timeout: 5))
        let shown = app.fieldValue("Password").displayedText

        revealButton.click()
        XCTAssertTrue(shown.waitForText(Fixture.password(of: Fixture.alpha), timeout: 3))
        AccessibilityTextProbe.assertTexts(of: app.fieldValue("Password"), equal: Fixture.password(of: Fixture.alpha))

        revealButton.click()
        XCTAssertTrue(shown.waitForText("••••••••", timeout: 3))
        AccessibilityTextProbe.assertTexts(of: app.fieldValue("Password"), equal: "••••••••")
    }

    // MARK: - Open in browser (safe-uri-launch)

    /// Gamma has a `file:` website, which must get no open button, and `example.com/login`, which
    /// opens as http. The row's identifier overrides its children's, so the button is found by its
    /// label, among links and buttons only (its image child carries the same label).
    func testOpenInBrowser_onlyForAllowedSchemes() {
        openItem(Fixture.gamma)
        // One predicate per query: an NSPredicate is not Sendable, so it can't be shared.
        let links = app.descendants(matching: .link).matching(NSPredicate(format: "label == %@", "Open Website"))
        let buttons = app.descendants(matching: .button).matching(NSPredicate(format: "label == %@", "Open Website"))
        let openButtons = links.count > 0 ? links : buttons
        XCTAssertTrue(openButtons.firstMatch.waitForExistence(timeout: 5), "example.com/login should be openable")
        XCTAssertEqual(openButtons.count, 1, "The file: website must not get an open button")
    }

    /// A website the integrity check hid is announced, never shown (uri-checksum-validation, D4).
    func testHiddenWebsitesNotice_isShownAndReadable() {
        openItem(Fixture.gamma)
        let notice = app.descendants(matching: .any)[Fixture.hiddenWebsitesNotice].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "1 website hidden because it failed an integrity check")

        openItem(Fixture.kappa)
        XCTAssertTrue(app.fieldValue("Website").displayedText.waitForText(Fixture.kappaWebsite, timeout: 5))
        XCTAssertFalse(notice.exists, "Kappa has no hidden website")
    }

    // MARK: - US3 Scenario 7: Item change resets mask state

    /// Verifies that navigating to a different item resets the reveal state to masked (FR-027).
    func testItemChangeResetsMaskState() {
        select("Login")
        openItem(Fixture.alpha)
        let revealButton = app.revealButton("Password")
        XCTAssertTrue(revealButton.waitForExistence(timeout: 5))
        let maskedValue = app.fieldValue("Password").displayedText
        revealButton.click()
        XCTAssertTrue(maskedValue.waitForText(Fixture.password(of: Fixture.alpha), timeout: 3),
                      "The first item's password should be revealed")

        openItem(Fixture.gamma)
        XCTAssertTrue(app.element("detail.name").waitForText("Gamma No Seed", timeout: 5),
                      "Detail should show the second item")
        XCTAssertTrue(maskedValue.waitForText("••••••••", timeout: 3), "Mask should reset on item change")
    }

    // MARK: - US3 Scenario 8: Last synced timestamp removed (no-toolbar-ui)

    /// The "Last synced" label was removed in the no-toolbar UI redesign; this checks it stays gone.
    func testLastSyncedTimestampVisible() {
        XCTAssertFalse(app.staticTexts["vault.lastSynced"].waitForExistence(timeout: 2),
                       "Last synced label should not exist after toolbar removal")
    }

    // MARK: - US3 Scenario 9: Sidebar categories always visible

    /// Verifies all sidebar categories are visible even when empty (FR-006, FR-042).
    func testSidebarCategoriesAlwaysVisible() {
        XCTAssertTrue(app.sidebarRow("All Items").waitForExistence(timeout: 5),
                      "All Items should always be visible")
        for title in ["Favorites", "Login", "Card", "Identity", "Secure Note", "SSH Key"] {
            XCTAssertTrue(app.sidebarRow(title).exists, "\(title) should always be visible")
        }
    }

    // MARK: - US3 Scenario 10: Empty list shows empty state message

    /// Verifies the item list shows an empty state when a category has no items (FR-042). The test
    /// vault has no SSH key.
    func testEmptyListShowsEmptyState() {
        select("SSH Key")
        XCTAssertTrue(app.element("itemList.empty").waitForExistence(timeout: 5),
                      "Empty state message should appear for an empty category")
    }

    // MARK: - Lock Vault (⌘L)

    func testLockVault_withCmdL_transitionsToUnlockScreen() {
        app.typeKey("l", modifierFlags: .command)

        XCTAssertTrue(app.staticTexts[AccessibilityID.Unlock.headerTitle].waitForExistence(timeout: 5),
                      "Unlock screen should appear after ⌘L")
        XCTAssertTrue(app.unlockSubtitle.exists, "Unlock screen should name the test account")
    }

    // MARK: - org-items-in-personal-folders 4.2

    /// An organization item filed in a personal folder shows in that folder. That it stays in its
    /// collection is covered by `OrgItemsInFoldersTests`; the organization is collapsed in the
    /// sidebar by default. Moving one there by drag and drop saves on the server, which the test
    /// states don't have.
    func testOrgItemFiledInFolder_showsInFolder() throws {
        app.terminate()
        app.launch(in: UITestLaunch.vault + ["--ui-test-org-folders"])
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")

        app.selectSidebarRow("Work")
        let row = app.element(Fixture.row("omega"))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The org item is listed in the folder it is filed in")
        // The row's identifier sits on each of its texts, so the badge is one of those texts.
        let badge = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR value == %@)", Fixture.row("omega"), "Acme", "Acme")).firstMatch
        XCTAssertTrue(badge.exists, "It still shows its organization")
    }
}
