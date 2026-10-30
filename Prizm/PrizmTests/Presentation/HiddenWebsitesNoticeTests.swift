import XCTest
@testable import Prizm

/// The login detail tells the user how many websites the integrity check hid (openspec change
/// `uri-checksum-validation`, design D4).
final class HiddenWebsitesNoticeTests: XCTestCase {

    func testOneWebsite() {
        XCTAssertEqual(LoginDetailView.hiddenWebsitesNotice(count: 1),
                       "1 website hidden because it failed an integrity check")
    }

    func testSeveralWebsites() {
        XCTAssertEqual(LoginDetailView.hiddenWebsitesNotice(count: 2),
                       "2 websites hidden because they failed an integrity check")
    }

    func testHintExplainsWhereItCameFromAndWhatASaveDoes() {
        XCTAssertEqual(LoginDetailView.hiddenWebsitesHint(count: 1),
                       "The server or another app changed this entry. Prizm doesn't use it, and the next save of this item removes it.")
        XCTAssertEqual(LoginDetailView.hiddenWebsitesHint(count: 2),
                       "The server or another app changed these entries. Prizm doesn't use them, and the next save of this item removes them.")
    }
}
