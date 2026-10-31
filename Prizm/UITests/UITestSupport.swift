import XCTest
import ApplicationServices

// Shared helpers for the UI journeys (openspec change `fix-ui-test-target`).

/// Base class for the UI journeys. When a test records a failure, it prints the app's UI hierarchy
/// at that moment into the test log, so a failure can be diagnosed from the log alone.
class PrizmUITestCase: XCTestCase {

    private var isDumping = false

    override func record(_ issue: XCTIssue) {
        if !isDumping {
            isDumping = true
            print("UI hierarchy at failure (\(name)):\n\(XCUIApplication().debugDescription)")
            isDumping = false
        }
        super.record(issue)
    }
}

/// Launch arguments of the app's DEBUG-only test states (`App/UITestFixtures.swift`, design D1).
/// In every state the app uses in-memory keychains, so a journey cannot touch the developer's
/// stored login.
enum UITestLaunch {
    /// Unlocked, with the seeded in-memory vault.
    static let vault = ["--ui-test-vault"]
    /// The unlock screen for the fixture account.
    static let locked = ["--ui-test-locked"]
    /// The login screen.
    static let signedOut = ["--ui-test-signed-out"]
}

/// What the seeded vault guarantees (`App/UITestFixtures.swift`, design D3). Row identifiers are
/// `itemList.row.<id>`.
enum Fixture {
    static let accountEmail = "uitest@example.com"
    /// Active logins, in the list's alphabetical order: Alpha Bank, Beta Mail, Delta Bad Seed,
    /// Gamma No Seed, Kappa Login.
    static let alpha = "alpha"
    static let gamma = "gamma"
    /// The only favourite; it also carries the only attachment.
    static let kappa = "kappa"
    /// Kappa's only website. Gamma's first website is `file:///Applications/Calculator.app`.
    static let kappaWebsite = "kappa.example.com/login"
    /// Gamma also has one website the integrity check hid; this is its notice row.
    static let hiddenWebsitesNotice = "detail.hiddenWebsites"
    static let card = "card1"
    static let identity = "ident1"
    static let note = "note1"
    /// In the trash.
    static let trashed = "zeta"
    static let attachmentId = "att1"
    static let attachmentFileName = "kappa-notes.txt"
    /// An attachment in Prizm's old file layout on the same item.
    static let legacyAttachmentId = "att-legacy"

    static func password(of id: String) -> String { "pw-\(id)" }
    static func row(_ id: String) -> String { "itemList.row.\(id)" }
}

/// Prerequisites a journey needs and a test run may not have (design D5). Each one is reported as a
/// skip with a fixed reason instead of passing without checking anything.
enum UITestPrerequisite {

    /// Saving anything goes to the server; the test states have none.
    static func serverWrites() throws -> Never {
        throw XCTSkip("Needs a test backend for saving (follow-up change ui-test-backend).")
    }

    /// Downloading an attachment needs the server; the test states have none.
    static func serverDownloads() throws -> Never {
        throw XCTSkip("Needs a test backend for downloads (follow-up change ui-test-backend).")
    }

    /// A journey that runs into a known app bug, which a separate change fixes. Skipped instead of
    /// run when the bug is a crash: a crash cannot be marked as an expected failure, and every run
    /// would leave a crash report dialog on the developer's screen.
    static func knownAppBug(_ description: String, fixedBy change: String) throws -> Never {
        throw XCTSkip("Known app bug: \(description) (to be fixed by \(change)).")
    }

    /// Touch ID cannot be simulated yet.
    static func biometrics() throws -> Never {
        throw XCTSkip("Needs simulated Touch ID (follow-up change ui-test-biometrics).")
    }

    struct RealAccount {
        let serverURL: String
        let email: String
        let password: String
    }

    /// A real account on a real server, from the test runner's environment. With `xcodebuild`, pass
    /// them as `TEST_RUNNER_BW_TEST_SERVER_URL` and so on (see DEVELOPMENT.md).
    static func realAccount(
        emailVariable: String = "BW_TEST_EMAIL",
        passwordVariable: String = "BW_TEST_PASSWORD"
    ) throws -> RealAccount {
        let names = ["BW_TEST_SERVER_URL", emailVariable, passwordVariable]
        let values = names.compactMap { name -> String? in
            guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
            return value
        }
        guard values.count == names.count else {
            throw XCTSkip("Needs a real account: set \(names.joined(separator: ", ")).")
        }
        return RealAccount(serverURL: values[0], email: values[1], password: values[2])
    }
}

extension XCUIApplication {
    /// Any element with the accessibility identifier `id`, wherever it is in the hierarchy.
    func element(_ id: String) -> XCUIElement {
        descendants(matching: .any)[id].firstMatch
    }

    /// Launches the app in a test state.
    func launch(in state: [String]) {
        launchArguments = state
        launch()
        openWindowIfNone()
    }

    /// The vault browser's sidebar. SwiftUI does not expose the browser's own identifier
    /// (`vault.navigationSplit`) or the sidebar rows' identifiers to accessibility; the sidebar is an
    /// outline labelled "Sidebar" and its rows are found by their titles.
    var sidebar: XCUIElement { outlines["Sidebar"] }

    /// A sidebar row by its visible title, for example "All Items", "Favorites", "Login" or "Trash".
    func sidebarRow(_ title: String) -> XCUIElement {
        sidebar.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
    }

    /// Selects a sidebar row by its title. `waitForVaultBrowser()` makes the window tall enough that
    /// the sidebar does not scroll: scrolling it from a test is unreliable, and a row the outline
    /// has not rendered reports a frame at the screen edge, so it cannot be scrolled into view.
    func selectSidebarRow(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = sidebarRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Sidebar row \(title) should exist", file: file, line: line)
        XCTAssertTrue(sidebar.frame.contains(row.frame),
                      "Sidebar row \(title) should be visible without scrolling; is the window too small?",
                      file: file, line: line)
        row.click()
    }

    /// Waits for the vault browser. On failure, prints the app's UI hierarchy into the test log,
    /// so the screen the app showed instead is visible without re-running.
    /// Also zooms a small window: macOS restores the last window size, which can be too small to
    /// show the whole sidebar (see `selectSidebarRow(_:)`).
    func waitForVaultBrowser(timeout: TimeInterval = 30) -> Bool {
        let found = sidebar.waitForExistence(timeout: timeout)
        if !found { print("Vault browser not found. UI hierarchy:\n\(debugDescription)") }
        if found { ensureLargeWindow() }
        return found
    }

    /// Opens the main window with File → New Window if the app shows none. Launched by XCUITest,
    /// the app gets no "reopen" event, so SwiftUI shows a window only if macOS restores one from the
    /// saved window state; after a run that ended without a window it shows none. This makes every
    /// test start the same way, whatever macOS saved.
    private func openWindowIfNone() {
        guard !windows.firstMatch.waitForExistence(timeout: 3) else { return }
        print("No window after launch; opening one with File → New Window")
        menuBars.menuBarItems["File"].click()
        menuBars.menuItems["New Window"].click()
    }

    /// Zooms the window with Window → Zoom when it is shorter than `minimumHeight`. Zoom toggles,
    /// so it is only used on a small window, and the new size is kept for the next launch.
    private func ensureLargeWindow(minimumHeight: CGFloat = 700) {
        let window = windows.firstMatch
        guard window.frame.height < minimumHeight else { return }
        menuBars.menuBarItems["Window"].click()
        menuBars.menuItems["Zoom"].click()
        let deadline = Date().addingTimeInterval(3)
        while window.frame.height < minimumHeight && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    /// The value of a detail-pane field row, for example "Password". The row's identifier
    /// `field.<label>` overrides the identifiers of its children (`masked.<label>.value`), so the
    /// value is the row's text that is not the field label itself.
    func fieldValue(_ label: String) -> XCUIElement {
        // A revealed value also brings a "COPY" text into the row.
        staticTexts.matching(NSPredicate(format: "identifier == %@ AND NOT (value IN %@)",
                                         "field.\(label)", [label, "COPY"])).firstMatch
    }

    /// The reveal/mask button of a masked field row (labelled "Reveal <label>" or "Hide <label>").
    func revealButton(_ label: String) -> XCUIElement {
        buttons["field.\(label)"].firstMatch
    }

    /// An element of the attachments section by its text. The section's identifier
    /// `attachment.section` overrides those of its rows and buttons (`attachment.button.add`,
    /// `attachment.row.<id>.*`), so elements are found by that identifier plus their label or value.
    func attachmentElement(_ type: XCUIElement.ElementType, _ text: String) -> XCUIElement {
        descendants(matching: type).matching(NSPredicate(
            format: "identifier == %@ AND (label == %@ OR value == %@)",
            AccessibilityID.Attachment.sectionCard, text, text)).firstMatch
    }

    /// An element of the attachments section of any type whose label or value contains `text`. A
    /// row reads its file name and size as one element ("report.pdf, 1 KB"), and the badge is an
    /// element of its own, so neither is a plain static text with exactly that label.
    func attachmentElement(containing text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            AccessibilityID.Attachment.sectionCard, text, text)).firstMatch
    }

    /// The unlock screen's subtitle, which names the stored account ("Enter the password for
    /// <email> to unlock."). The screen has no separate email field since ba1cd07 (#39).
    var unlockSubtitle: XCUIElement {
        staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                         Fixture.accountEmail, Fixture.accountEmail)).firstMatch
    }

    /// The toolbar search field. In a narrow window the toolbar collapses it into a Search button.
    func searchField() -> XCUIElement {
        let field = searchFields.firstMatch
        if !field.waitForExistence(timeout: 2), buttons["Search"].exists {
            buttons["Search"].click()
        }
        return field
    }
}

extension XCUIElement {
    /// The visible text. SwiftUI exposes many texts as the accessibility value, not the label.
    var text: String { label.isEmpty ? (value as? String ?? "") : label }

    /// The text a selectable `Text` (`.textSelection(.enabled)`) currently shows. Accessibility
    /// wraps such a text in an outer element that carries the identifier but keeps its first value;
    /// only the inner text element follows changes (seen for the masked field value and the
    /// generator preview). Wait on this element, not on the outer one, for a text change.
    var displayedText: XCUIElement { staticTexts.firstMatch }

    /// Waits until the element's text (label and value) no longer equals `text`.
    func waitForTextChange(from text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label != %@ AND value != %@", text, text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits until the element's text (label or value) equals `text`.
    func waitForText(_ text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", text, text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

// MARK: - What VoiceOver reads by text range

/// Reads a text the way VoiceOver can: through its character data (`AXNumberOfCharacters` and
/// `AXStringForRange`), not its accessibility value. XCUITest only sees the value, which a selectable
/// text keeps current while its character data kept the old text (fix-selectable-text-voiceover).
///
/// Needs the accessibility permission for the test runner (`PrizmUITests-Runner`). macOS ties it to
/// the runner binary, so it is lost whenever the UI test code changes; without it the tests skip.
enum AccessibilityTextProbe {

    static var isAvailable: Bool { AXIsProcessTrusted() }

    static let unavailableMessage = "Needs the accessibility permission for PrizmUITests-Runner "
        + "(System Settings, Privacy & Security, Accessibility); macOS drops it whenever the UI test code changes"

    /// Asserts that the value text at the centre of `element` holds `expected` in its character data
    /// too. Of the element hit there and its parent, only those whose accessibility value is
    /// `expected` are checked: they are the value texts, so a hover overlay or a container is never
    /// checked by mistake. At least one must exist, so the assertion can't pass vacuously.
    static func assertTexts(of element: XCUIElement, equal expected: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let texts = textsByRange(at: element.frame, showing: expected)
        XCTAssertFalse(texts.isEmpty, "No text showing \"\(expected)\" with character data at \(element.frame)",
                       file: file, line: line)
        for text in texts {
            XCTAssertEqual(text, expected, "VoiceOver can read this text by range", file: file, line: line)
        }
    }

    private static func textsByRange(at frame: CGRect, showing shown: String) -> [String] {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(frame.midX),
                                               Float(frame.midY), &hit) == .success,
              let hit else { return [] }
        return [hit, parent(of: hit)].compactMap { $0 }
            .filter { value(of: $0) == shown }
            .compactMap(textByRange)
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func textByRange(of element: AXUIElement) -> String? {
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let length = count as? Int else { return nil }
        var range = CFRange(location: 0, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &text) == .success else { return nil }
        return text as? String
    }
}
