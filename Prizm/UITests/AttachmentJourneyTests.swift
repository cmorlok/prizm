import XCTest

/// XCUITest: Attachment Upload / Open / Delete Journey (vault-document-storage task 9.1)
///
/// Runs on the seeded test vault (`UITestLaunch.vault`): the favourite fixture login carries one
/// attachment entry (`Fixture.attachmentFileName`). The section, the add button and the row are
/// checked locally. Opening (download) and deleting need a server and are reported as skipped
/// at that step.
final class AttachmentJourneyTests: PrizmUITestCase {

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

    /// Opens the fixture item with the attachment and returns its attachments section.
    private func openItemWithAttachment() -> XCUIElement {
        let row = app.element(Fixture.row(Fixture.kappa))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Fixture item Kappa Login should be listed")
        row.click()
        let section = app.element(AccessibilityID.Attachment.sectionCard)
        XCTAssertTrue(section.waitForExistence(timeout: 5),
                      "Attachments section card must be visible in the detail pane")
        return section
    }

    // MARK: - 9.1.1: Attachments section card is visible

    func testAttachmentSection_isVisibleOnDetailPane() {
        _ = openItemWithAttachment()
    }

    // MARK: - 9.1.2: "Add Attachment" button is present

    func testAttachmentSection_addButtonIsPresent() {
        _ = openItemWithAttachment()
        let addButton = app.attachmentElement(.button, "Add Attachment")
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Add Attachment button must be visible")
        XCTAssertTrue(addButton.isEnabled, "Add Attachment button must be enabled")
    }

    // MARK: - 9.1.3: Seeded attachment row is visible

    func testAttachmentSection_preSeededRow_isVisible() {
        _ = openItemWithAttachment()
        XCTAssertTrue(app.attachmentElement(containing: Fixture.attachmentFileName).waitForExistence(timeout: 5),
                      "The seeded attachment row must show the file name")
    }

    // MARK: - fix-attachment-file-format 4.4: old file layout

    /// The badge and the Convert action of an attachment in Prizm's old layout, with their VoiceOver
    /// texts. Converting needs a server; the rig check covers it (task 5.1). Elements in the card
    /// carry the card's identifier, so they are found by text (`attachmentElement`).
    func testLegacyAttachment_showsBadgeAndConvert() {
        _ = openItemWithAttachment()
        let badge = app.attachmentElement(containing: "Saved in old Prizm format. Other Bitwarden apps can't open it.")
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "The old-format attachment shows its badge, read by VoiceOver")
        let converts = app.descendants(matching: .button).matching(NSPredicate(
            format: "identifier == %@ AND label == %@", AccessibilityID.Attachment.sectionCard, "Convert"))
        XCTAssertEqual(converts.count, 1, "Convert is visible without hovering, only on the old-format attachment")
    }

    // MARK: - 9.1.4: Open → progress resolves without error

    /// Opening downloads the file from the server.
    func testAttachmentOpen_progressResolvesWithoutError() throws {
        _ = openItemWithAttachment()
        XCTAssertTrue(app.attachmentElement(containing: Fixture.attachmentFileName).waitForExistence(timeout: 5))
        try UITestPrerequisite.serverDownloads()
    }

    // MARK: - 9.1.5: Delete → confirm → row disappears

    /// Deleting removes the attachment on the server.
    func testAttachmentDelete_removesRow() throws {
        _ = openItemWithAttachment()
        XCTAssertTrue(app.attachmentElement(containing: Fixture.attachmentFileName).waitForExistence(timeout: 5))
        try UITestPrerequisite.serverWrites()
    }
}

/// XCUITest: Attachment Drag-and-Drop Batch Upload Journey (vault-document-storage task 9.2)
///
/// Verifies the drop target exists. Automating a real drop is not practical in XCUITest.
final class AttachmentBatchJourneyTests: PrizmUITestCase {

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

    // MARK: - 9.2.1: Attachments section accepts drop (structural check)

    func testAttachmentSection_dropTarget_exists() {
        let row = app.element(Fixture.row(Fixture.kappa))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()

        let section = app.element(AccessibilityID.Attachment.sectionCard)
        XCTAssertTrue(section.waitForExistence(timeout: 5),
                      "Attachments section card (drop target) must be visible in the detail pane")
        XCTAssertTrue(section.isHittable, "Attachments section card must be hittable (required for drop target)")
    }
}
