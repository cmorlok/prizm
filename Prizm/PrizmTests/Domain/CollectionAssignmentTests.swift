import XCTest
@testable import Prizm

/// `CollectionAssignment.finalIds` (openspec change `fix-collection-assignment`, design D2): the
/// writable selection replaces only writable assignments; everything else the item is in is kept.
final class CollectionAssignmentTests: XCTestCase {

    private struct Case {
        let name: String
        let original: [String]
        let selected: [String]
        let writable: Set<String>
        let expected: [String]
    }

    func testFinalIds() {
        let cases = [
            Case(name: "unchanged", original: ["A", "B"], selected: ["A", "B"], writable: ["A", "B", "C"],
                 expected: ["A", "B"]),
            Case(name: "add a writable one, after the original ones", original: ["A"], selected: ["A", "C"],
                 writable: ["A", "C"], expected: ["A", "C"]),
            Case(name: "remove a writable one", original: ["A", "B"], selected: ["A"], writable: ["A", "B"],
                 expected: ["A"]),
            Case(name: "read-only assignment kept", original: ["A", "R"], selected: ["A", "C"],
                 writable: ["A", "C"], expected: ["A", "R", "C"]),
            Case(name: "unknown id kept", original: ["X", "A"], selected: [], writable: ["A"],
                 expected: ["X"]),
            Case(name: "other organization's id kept", original: ["other-org-col", "A"], selected: ["B"],
                 writable: ["A", "B"], expected: ["other-org-col", "B"]),
            Case(name: "a selected id that is not writable is never added", original: ["A"], selected: ["A", "R"],
                 writable: ["A"], expected: ["A"]),
            Case(name: "empty result", original: ["A"], selected: [], writable: ["A"], expected: []),
            Case(name: "duplicates collapse", original: ["A", "A"], selected: ["A", "C", "C"], writable: ["A", "C"],
                 expected: ["A", "C"]),
        ]
        for c in cases {
            XCTAssertEqual(CollectionAssignment.finalIds(original: c.original, selectedWritable: c.selected,
                                                         writableIds: c.writable),
                           c.expected, c.name)
        }
    }

    /// The user's change, applied to the collections the server holds now. Vaultwarden 1.37.4 does
    /// not change an item's revision when its collections change (live rig 2026-10-30), so a sync
    /// while the sheet is open can bring in another member's change without a conflict.
    func testRebased() {
        let cases: [(String, [String], [String], [String], [String])] = [
            ("no change by anyone", ["A"], ["A"], ["A"], ["A"]),
            ("added elsewhere, nothing here", ["A", "B"], ["A"], ["A"], ["A", "B"]),
            ("added elsewhere, one added here", ["A", "B"], ["A"], ["A", "C"], ["A", "B", "C"]),
            ("removed elsewhere, one added here", ["A"], ["A", "B"], ["A", "B", "C"], ["A", "C"]),
            ("removed here", ["A", "B", "R"], ["A", "R"], ["R"], ["B", "R"]),
            ("added here and elsewhere", ["A", "C"], ["A"], ["A", "C"], ["A", "C"]),
        ]
        for (name, stored, original, edited, expected) in cases {
            XCTAssertEqual(CollectionAssignment.rebased(stored: stored, original: original, edited: edited), expected, name)
        }
    }
}
