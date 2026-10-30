import XCTest

/// XCUITest: Password Generator Journey (password-generator tasks 5.1–5.2)
///
/// Validates the generator popover flow: opening from the Login edit sheet,
/// interacting with controls, and applying the generated value.
///
/// Runs on the seeded test vault (`UITestLaunch.vault`). Nothing is saved: the edit sheet is
/// discarded at the end. The generator stores its options in the app's preferences, which a test
/// run changes (design.md of fix-ui-test-target, Risks).
final class PasswordGeneratorJourneyTests: PrizmUITestCase {

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

    // MARK: - What VoiceOver reads by text range (fix-selectable-text-voiceover)

    /// The preview is a selectable text: a new value must also reach its character data.
    func testGeneratorPreview_textByRangeFollowsNewValue() throws {
        try XCTSkipUnless(AccessibilityTextProbe.isAvailable, AccessibilityTextProbe.unavailableMessage)
        let row = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "The detail pane should offer Edit")
        editButton.click()
        let generatorButton = app.buttons["generator.button.trigger"]
        XCTAssertTrue(generatorButton.waitForExistence(timeout: 5), "The edit sheet should offer the generator")
        generatorButton.click()

        let preview = app.staticTexts["generator.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Generator popover should be open")
        let previewText = preview.displayedText
        let first = previewText.text
        app.buttons["generator.button.refresh"].click()
        XCTAssertTrue(previewText.waitForTextChange(from: first, timeout: 3), "A new value should be shown")
        AccessibilityTextProbe.assertTexts(of: preview, equal: previewText.text)

        // Nothing is saved: use the value, then discard the edit sheet.
        app.buttons["generator.button.use"].click()
        let discardButton = app.buttons["edit.button.discard"]
        if discardButton.waitForExistence(timeout: 2) { discardButton.click() }
    }

    // MARK: - Task 5.1: Generator popover opens, slider changes preview, Use applies value

    func testGeneratorPopover_opensAndAppliesPassword() throws {
        // Select a Login item from the sidebar.
        let sidebarLogins = app.sidebarRow("Login")
        XCTAssertTrue(sidebarLogins.waitForExistence(timeout: 5))
        sidebarLogins.click()

        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        // Open the edit sheet.
        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()

        // Tap the generator trigger button.
        let generatorButton = app.buttons["generator.button.trigger"]
        XCTAssertTrue(generatorButton.waitForExistence(timeout: 3), "Generator button should be visible")
        generatorButton.click()

        // Verify the popover opened — preview should exist.
        let preview = app.staticTexts["generator.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3), "Generator popover should be open")
        let previewText = preview.displayedText

        // The generator keeps its options in the app's preferences, so it may open in Passphrase
        // mode from an earlier run; the length slider exists only in Password mode.
        let passwordTab = app.radioButtons["Password"]
        XCTAssertTrue(passwordTab.waitForExistence(timeout: 2))
        passwordTab.click()

        // Change the length. The slider may start anywhere: move it to the other end.
        let slider = app.sliders["generator.lengthSlider"]
        _ = slider.waitForExistence(timeout: 2)
        let initialPreview = previewText.text
        XCTAssertTrue(slider.exists, "Length slider should be visible")
        let positionBefore = slider.normalizedSliderPosition
        slider.adjust(toNormalizedSliderPosition: positionBefore > 0.5 ? 0.1 : 0.9)

        // Separate checks, so a failure says which step went wrong.
        XCTAssertNotEqual(slider.normalizedSliderPosition, positionBefore, accuracy: 0.05,
                          "The slider should have moved")
        XCTAssertTrue(preview.exists, "The generator popover should still be open after moving the slider")
        XCTAssertTrue(previewText.waitForTextChange(from: initialPreview, timeout: 3),
                      "Preview should update after slider change")
        XCTAssertEqual(preview.text, previewText.text, "VoiceOver should read the new value")

        // Tap "Use Password".
        let useButton = app.buttons["generator.button.use"]
        XCTAssertTrue(useButton.exists)
        useButton.click()

        // Verify popover dismissed.
        XCTAssertFalse(preview.waitForExistence(timeout: 2), "Popover should have dismissed")

        // Discard the edit sheet: nothing is saved.
        let discardButton = app.buttons["edit.button.discard"]
        if discardButton.waitForExistence(timeout: 2) { discardButton.click() }
    }

    // MARK: - fix-password-generator: symbol sets and minimums

    /// The two symbol sets and the minimum steppers are present and named for VoiceOver. Nothing
    /// is toggled: the run shares the developer's generator preferences.
    func testGeneratorPopover_showsSymbolSetsAndMinimums() throws {
        let sidebarLogins = app.sidebarRow("Login")
        XCTAssertTrue(sidebarLogins.waitForExistence(timeout: 5))
        sidebarLogins.click()
        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()
        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()
        let generatorButton = app.buttons["generator.button.trigger"]
        XCTAssertTrue(generatorButton.waitForExistence(timeout: 3))
        generatorButton.click()

        let modePicker = app.descendants(matching: .any)["generator.modePicker"].firstMatch
        XCTAssertTrue(modePicker.waitForExistence(timeout: 3))
        modePicker.radioButtons["Password"].firstMatch.click()

        let special = app.descendants(matching: .any)["generator.toggle.symbols"].firstMatch
        XCTAssertTrue(special.waitForExistence(timeout: 3))
        XCTAssertEqual(special.label, "Special characters")
        let extended = app.descendants(matching: .any)["generator.toggle.extendedSymbols"].firstMatch
        XCTAssertTrue(extended.exists)
        XCTAssertEqual(extended.label, "Extended special characters")
        XCTAssertTrue(app.descendants(matching: .any)["generator.minNumbers"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["generator.minSpecial"].firstMatch.exists)

        app.typeKey(.escape, modifierFlags: [])
        let discardButton = app.buttons["edit.button.discard"]
        if discardButton.waitForExistence(timeout: 2) { discardButton.click() }
    }

    // MARK: - Task 5.2: Switch to Passphrase mode, change word count, verify preview

    func testGeneratorPopover_passphraseMode_wordCountUpdatesPreview() throws {
        // Select a Login item.
        let sidebarLogins = app.sidebarRow("Login")
        XCTAssertTrue(sidebarLogins.waitForExistence(timeout: 5))
        sidebarLogins.click()

        let firstRow = app.element(Fixture.row(Fixture.alpha))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()

        // Open edit sheet.
        let editButton = app.buttons["edit.button.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.click()

        // Open generator popover.
        let generatorButton = app.buttons["generator.button.trigger"]
        XCTAssertTrue(generatorButton.waitForExistence(timeout: 3))
        generatorButton.click()

        let preview = app.staticTexts["generator.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        let previewText = preview.displayedText

        // Switch to Passphrase mode. The mode picker is segmented, which accessibility exposes as
        // radio buttons. It may already be selected from an earlier run (preferences persist).
        let passphraseTab = app.radioButtons["Passphrase"]
        XCTAssertTrue(passphraseTab.waitForExistence(timeout: 2))
        passphraseTab.click()
        XCTAssertTrue(preview.exists, "The generator popover should still be open after choosing Passphrase")

        let stepper = app.steppers["generator.wordCount"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 3), "Word count stepper should be visible")
        // Accessibility does not report the segment's selection reliably; check its effect instead.
        let separated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS '-' OR value CONTAINS '-'"), object: previewText)
        XCTAssertEqual(XCTWaiter().wait(for: [separated], timeout: 3), .completed,
                       "Passphrase should contain separator")
        let passphrasePreview = previewText.text

        // Change the word count (3 to 20). The stepper exposes its arrows as increment and
        // decrement arrows, not as buttons. At the maximum, Increment does nothing, so step down then.
        stepper.incrementArrows.firstMatch.click()
        if !previewText.waitForTextChange(from: passphrasePreview, timeout: 2) {
            stepper.decrementArrows.firstMatch.click()
        }
        XCTAssertTrue(previewText.waitForTextChange(from: passphrasePreview, timeout: 3),
                      "Preview should update after word count change")

        // Close the popover and discard the edit sheet: nothing is saved.
        app.typeKey(.escape, modifierFlags: [])
        let discardButton = app.buttons["edit.button.discard"]
        if discardButton.waitForExistence(timeout: 2) { discardButton.click() }
    }
}
