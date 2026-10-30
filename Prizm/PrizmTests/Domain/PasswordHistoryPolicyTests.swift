import XCTest
@testable import Prizm

/// Which values a save adds to the password history (openspec change `password-history`, task 3.1).
/// The rules are the Bitwarden SDK's (`detect_password_change`, `detect_hidden_field_changes`,
/// `update_password_history`); see `PasswordHistoryPolicy`.
final class PasswordHistoryPolicyTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }
    private func f(_ name: String, _ value: String) -> PasswordHistoryPolicy.HiddenField {
        .init(name: d(name), value: d(value))
    }
    private func entries(old: String?, new: String = "",
                         oldHidden: [PasswordHistoryPolicy.HiddenField] = [],
                         newHidden: [PasswordHistoryPolicy.HiddenField] = []) -> [String] {
        PasswordHistoryPolicy.newEntries(oldPassword: old.map(d), newPassword: d(new),
                                         oldHidden: oldHidden, newHidden: newHidden)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Password

    func testPassword_changedOrCleared_addsTheOldPassword() {
        XCTAssertEqual(entries(old: "old", new: "new"), ["old"])
        XCTAssertEqual(entries(old: "old", new: ""), ["old"], "cleared")
    }

    func testPassword_unchangedEmptyOrMissing_addsNothing() {
        XCTAssertEqual(entries(old: "same", new: "same"), [])
        XCTAssertEqual(entries(old: "", new: "first"), [], "a first password only sets the date")
        XCTAssertEqual(entries(old: nil, new: "x"), [], "no stored login section")
    }

    func testPassword_caseOrWhitespaceChange_counts() {
        XCTAssertEqual(entries(old: "same", new: "Same"), ["same"])
        XCTAssertEqual(entries(old: "same", new: "same "), ["same"])
    }

    // MARK: - Hidden fields

    func testHiddenField_changedRemovedOrRenamed_addsNameAndOldValue() {
        XCTAssertEqual(entries(old: nil, oldHidden: [f("PIN", "1234")], newHidden: [f("PIN", "9999")]), ["PIN: 1234"])
        XCTAssertEqual(entries(old: nil, oldHidden: [f("PIN", "1234")], newHidden: []), ["PIN: 1234"], "removed")
        XCTAssertEqual(entries(old: nil, oldHidden: [f("PIN", "1234")], newHidden: [f("Code", "1234")]), ["PIN: 1234"],
                       "a rename is a removal")
    }

    func testHiddenField_unchanged_addsNothing() {
        XCTAssertEqual(entries(old: nil, oldHidden: [f("PIN", "1234")], newHidden: [f("PIN", "1234")]), [])
    }

    func testHiddenField_emptyNameOrValue_isIgnored() {
        XCTAssertEqual(entries(old: nil, oldHidden: [f("", "1234"), f("PIN", "")], newHidden: []), [])
        // A new value that is empty is no value: the stored one is recorded.
        XCTAssertEqual(entries(old: nil, oldHidden: [f("PIN", "1234")], newHidden: [f("PIN", "")]), ["PIN: 1234"])
    }

    func testHiddenField_duplicateNames_lastOneWinsOnBothSides() {
        XCTAssertEqual(entries(old: nil, oldHidden: [f("PIN", "1"), f("PIN", "2")], newHidden: [f("PIN", "2")]), [])
        XCTAssertEqual(entries(old: nil, oldHidden: [f("PIN", "1")], newHidden: [f("PIN", "1"), f("PIN", "3")]), ["PIN: 1"])
    }

    // MARK: - Order

    func testOrder_passwordThenFieldsIsReversed() {
        let result = entries(old: "pw", new: "new",
                             oldHidden: [f("A", "a"), f("B", "b")], newHidden: [])
        XCTAssertEqual(result, ["B: b", "A: a", "pw"])
    }

    func testCap_isFive() {
        XCTAssertEqual(PasswordHistoryPolicy.maxEntries, 5)
    }
}
