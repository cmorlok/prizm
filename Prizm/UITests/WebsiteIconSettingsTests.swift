import XCTest

/// XCUITest: the "Privacy" section of the Settings window (fix-website-icons-privacy, task 3.4).
///
/// The two settings live in the app's standard `UserDefaults`, which a UI-test run shares with the
/// developer's own Prizm: the test notes both values first and clicks them back at the end.
/// Runs in the seeded vault (`UITestLaunch.vault`).
final class WebsiteIconSettingsTests: PrizmUITestCase {

    private var app: XCUIApplication!
    /// The developer's two values, noted before the test changes them and clicked back afterwards.
    private var original: (show: Bool, other: Bool)?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch(in: UITestLaunch.vault)
        XCTAssertTrue(app.waitForVaultBrowser(), "Vault browser must be visible")
    }

    override func tearDownWithError() throws {
        if let original, app != nil {
            if !showIcons.exists { openSettings() }
            set(showIcons, to: true)          // "other services" is clickable only while icons are on
            set(otherServices, to: original.other)
            set(showIcons, to: original.show)
        }
        app = nil
    }

    private var showIcons: XCUIElement { app.element("settings.icons.showWebsiteIcons") }
    private var otherServices: XCUIElement { app.element("settings.icons.allowOtherServices") }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        if let number = toggle.value as? NSNumber { return number.boolValue }
        return (toggle.value as? String) == "1"
    }

    private func openSettings() {
        let gear = app.buttons["vault.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Settings button must exist")
        gear.click()
        XCTAssertTrue(showIcons.waitForExistence(timeout: 5), "Settings must show the Privacy section")
    }

    /// Closes the Settings window with its own close button (no keyboard shortcut).
    private func closeSettings() {
        let window = app.windows.containing(.any, identifier: "settings.icons.showWebsiteIcons").firstMatch
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(showIcons.waitForNonExistence(timeout: 5), "Settings must close")
    }

    private func set(_ toggle: XCUIElement, to value: Bool) {
        if isOn(toggle) != value { toggle.click() }
        XCTAssertEqual(isOn(toggle), value, toggle.identifier)
    }

    func testPrivacyToggles_labelsDependencyAndPersistence() {
        openSettings()
        original = (isOn(showIcons), isOn(otherServices))

        XCTAssertEqual(showIcons.label, "Show website icons")
        XCTAssertEqual(otherServices.label, "Allow icons from other services")

        set(showIcons, to: true)
        XCTAssertTrue(otherServices.isEnabled, "other services can be allowed while icons are on")
        set(otherServices, to: true)

        set(showIcons, to: false)
        XCTAssertFalse(otherServices.isEnabled, "other services are disabled while icons are off")

        closeSettings()
        openSettings()
        XCTAssertFalse(isOn(showIcons), "Show website icons keeps its value")
        XCTAssertTrue(isOn(otherServices), "Allow icons from other services keeps its value")
        XCTAssertFalse(otherServices.isEnabled)
    }
}
