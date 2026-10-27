import XCTest
@testable import Prizm

/// The conflict banner's accessibility identifiers are the contract the UI journeys use to tell
/// which banner state a sheet reached, so their values are pinned here.
final class ConflictBannerIdentifierTests: XCTestCase {

    func testConflictIdentifiers_haveTheirContractValues() {
        XCTAssertEqual(AccessibilityID.Edit.conflictReloadButton, "edit.button.conflictReload")
        XCTAssertEqual(AccessibilityID.Edit.conflictCloseButton, "edit.button.conflictClose")
        XCTAssertEqual(AccessibilityID.Edit.conflictStatus, "edit.conflictStatus")
        XCTAssertEqual(AccessibilityID.Edit.errorBanner, "edit.errorBanner")
    }
}
