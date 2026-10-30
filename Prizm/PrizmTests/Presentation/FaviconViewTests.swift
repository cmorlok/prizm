import XCTest
@testable import Prizm

/// fix-website-icons-privacy, D2: `FaviconView` loads an icon only for a website host and only while
/// "Show website icons" is on. Tested at unit level: the view is hidden from VoiceOver, and UI-test
/// mode loads no icons.
final class FaviconViewTests: XCTestCase {

    func testLoadsTheDomain_whileIconsAreOn() {
        XCTAssertEqual(FaviconView.loadTarget(domain: "github.com", showsIcons: true), "github.com")
    }

    func testLoadsNothing_whileIconsAreOff() {
        XCTAssertNil(FaviconView.loadTarget(domain: "github.com", showsIcons: false))
    }

    func testLoadsNothing_withoutADomain() {
        XCTAssertNil(FaviconView.loadTarget(domain: nil, showsIcons: true))
    }

    /// The `.task(id:)` key changes with the setting, so turning icons off or on reloads the view.
    func testTaskKey_changesWithTheSetting() {
        XCTAssertNotEqual(FaviconView.TaskKey(domain: "github.com", showsIcons: true),
                          FaviconView.TaskKey(domain: "github.com", showsIcons: false))
    }
}
