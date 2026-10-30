import XCTest
@testable import Prizm

final class TOTPCodeTests: XCTestCase {

    func test_grouped_sixDigits() {
        XCTAssertEqual(TOTPCode(digits: "123456", period: 30, secondsRemaining: 10).grouped, "123 456")
    }

    func test_grouped_eightDigits() {
        XCTAssertEqual(TOTPCode(digits: "12345678", period: 30, secondsRemaining: 10).grouped, "1234 5678")
    }

    func test_grouped_sevenDigits_splitsInTheMiddle() {
        XCTAssertEqual(TOTPCode(digits: "1234567", period: 30, secondsRemaining: 10).grouped, "123 4567")
    }

    func test_grouped_onlyAboveFourCharacters() {
        XCTAssertEqual(TOTPCode(digits: "7", period: 30, secondsRemaining: 10).grouped, "7")
        XCTAssertEqual(TOTPCode(digits: "1234", period: 30, secondsRemaining: 10).grouped, "1234")
        XCTAssertEqual(TOTPCode(digits: "1234567890", period: 30, secondsRemaining: 10).grouped, "12345 67890")
    }

    func test_steam_groupsTwoThree_andCopiesWithoutSpace() {
        let code = TOTPCode(digits: "7W6CJ", period: 30, secondsRemaining: 10)
        XCTAssertEqual(code.grouped, "7W 6CJ")
        XCTAssertEqual(code.copyValue, "7W6CJ")
    }

    func test_copyValue_hasNoSpace() {
        XCTAssertEqual(TOTPCode(digits: "123456", period: 30, secondsRemaining: 10).copyValue, "123456")
    }

    func test_leadingZeros_arePreserved() {
        let code = TOTPCode(digits: "007081", period: 30, secondsRemaining: 10)
        XCTAssertEqual(code.copyValue, "007081")
        XCTAssertEqual(code.grouped, "007 081")
    }

    func test_isExpiringSoon_boundary() {
        XCTAssertTrue(TOTPCode(digits: "123456", period: 30, secondsRemaining: 5).isExpiringSoon)
        XCTAssertTrue(TOTPCode(digits: "123456", period: 30, secondsRemaining: 1).isExpiringSoon)
        XCTAssertFalse(TOTPCode(digits: "123456", period: 30, secondsRemaining: 6).isExpiringSoon)
    }
}
