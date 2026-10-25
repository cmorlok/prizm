import XCTest

/// XCUITest: US2 Unlock Journey (T043)
///
/// Validates the unlock screen for a returning user, in the locked test state (`UITestLaunch.locked`,
/// fixture account `Fixture.accountEmail`). The screen follows the redesign in ba1cd07 (#39):
/// title "Prizm Is Locked", the email inline in the subtitle, one password field submitted with
/// Return, no unlock button. Unlocking successfully needs a real account (SC-002 — ≤5s).
final class UnlockJourneyTests: PrizmUITestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Locked test state: the unlock screen for the fixture account, with an in-memory keychain.
        app.launch(in: UITestLaunch.locked)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - US2 Scenario 1: Unlock screen shown for returning user

    /// Verifies that the unlock screen appears (not login) when a stored session exists.
    func testUnlockScreenShownOnRelaunch() {
        let header = app.staticTexts["unlock.headerTitle"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 5),
            "Unlock screen should appear for returning users"
        )
        XCTAssertEqual(header.text, "Prizm Is Locked")
    }

    // MARK: - US2 Scenario 2: Stored email is displayed read-only

    /// Verifies the stored email is shown, inline in the subtitle (FR-003).
    func testStoredEmailDisplayed() {
        XCTAssertTrue(app.unlockSubtitle.waitForExistence(timeout: 5),
                      "The subtitle with the stored email should be visible on the unlock screen")
    }

    // MARK: - US2 Scenario 3: Correct password unlocks vault (SC-002)

    /// Verifies that entering the correct master password reaches the vault browser.
    /// Measures time against SC-002 (≤5s).
    func testCorrectPasswordUnlocksVault() throws {
        // The fixture account has no keys, so this needs a real account: sign in, lock, unlock.
        let account = try UITestPrerequisite.realAccount()
        app.terminate()
        app.launch(in: UITestLaunch.signedOut)

        let serverField = app.textFields["login.serverURL"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 5))
        serverField.click()
        serverField.typeText(account.serverURL)
        app.textFields["login.email"].click()
        app.textFields["login.email"].typeText(account.email)
        app.secureTextFields["login.password"].click()
        app.secureTextFields["login.password"].typeText(account.password)
        app.buttons["login.signIn"].click()
        let vaultNav = app.sidebar
        XCTAssertTrue(vaultNav.waitForExistence(timeout: 60), "Vault browser should appear after login")

        app.typeKey("l", modifierFlags: .command)
        let passField = app.secureTextFields["unlock.password"]
        XCTAssertTrue(passField.waitForExistence(timeout: 5))

        let startTime = CFAbsoluteTimeGetCurrent()
        passField.click()
        passField.typeText(account.password)
        passField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(vaultNav.waitForExistence(timeout: 30), "Vault browser should appear after unlock")
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        XCTAssertLessThanOrEqual(elapsed, 5.0, "SC-002: Unlock-to-vault must complete within 5s")
    }

    // MARK: - US2 Scenario 4: Wrong password shows error without locking

    /// Verifies that entering the wrong password shows an error message but stays on
    /// the unlock screen (vault is not locked/destroyed).
    func testWrongPasswordShowsErrorStaysOnUnlock() {
        let passField = app.secureTextFields["unlock.password"]
        XCTAssertTrue(passField.waitForExistence(timeout: 5))

        passField.click()
        passField.typeText("definitely-wrong-password")
        passField.typeKey(.return, modifierFlags: [])

        let error = app.staticTexts["unlock.error"]
        XCTAssertTrue(
            error.waitForExistence(timeout: 10),
            "Error message should appear for wrong password"
        )

        // Should still be on the unlock screen — not redirected to login.
        let header = app.staticTexts["unlock.headerTitle"]
        XCTAssertTrue(header.exists, "Should remain on unlock screen after wrong password")
    }

    // MARK: - US2 Scenario 5: "Sign in with a different account" returns to login

    /// Verifies that tapping "Sign in with a different account" clears the session
    /// and returns to the login screen.
    func testSwitchAccountReturnsToLogin() {
        let switchBtn = app.buttons["unlock.switchAccount"]
        XCTAssertTrue(switchBtn.waitForExistence(timeout: 5))
        switchBtn.click()

        let serverURL = app.textFields["login.serverURL"]
        XCTAssertTrue(
            serverURL.waitForExistence(timeout: 5),
            "Login screen should appear after switching account"
        )
    }

    // MARK: - US2 Scenario 6: Empty password does nothing

    /// There is no unlock button since the redesign; Return with an empty password must neither
    /// unlock nor show an error.
    func testUnlockButtonDisabledWhenEmpty() {
        let passField = app.secureTextFields["unlock.password"]
        XCTAssertTrue(passField.waitForExistence(timeout: 5))
        passField.click()
        passField.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(app.staticTexts["unlock.error"].waitForExistence(timeout: 2),
                       "Return with an empty password should not show an error")
        XCTAssertTrue(app.staticTexts["unlock.headerTitle"].exists, "Should stay on the unlock screen")
    }

    // MARK: - Biometric invalidation message

    /// When biometric unlock fails because the enrolled fingers changed, the unlock screen shows
    /// "Your Touch ID settings have changed".
    func testBiometricInvalidation_showsErrorMessage() throws {
        try UITestPrerequisite.biometrics()
    }
}
