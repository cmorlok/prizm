import XCTest
@testable import Prizm

@MainActor
final class HighlightedTextTests: XCTestCase {

    // MARK: - Match applies bold

    func testHighlightedText_matchAppliesBold() {
        let result = ItemRowView.highlightedText("Hello World", query: "World")
        let runs = Array(result.runs)
        XCTAssertEqual(runs.count, 2)
        XCTAssertNil(runs[0].attributes.inlinePresentationIntent)
        XCTAssertEqual(runs[1].attributes.inlinePresentationIntent, .stronglyEmphasized)
    }

    // MARK: - No match returns plain

    func testHighlightedText_noMatch_returnsPlain() {
        let result = ItemRowView.highlightedText("Hello World", query: "xyz")
        let runs = Array(result.runs)
        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs[0].attributes.inlinePresentationIntent)
    }

    // MARK: - Case-insensitive matching

    func testHighlightedText_caseInsensitive() {
        let result = ItemRowView.highlightedText("Alice's Bank", query: "alice")
        let runs = Array(result.runs)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].attributes.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(String(result.characters[runs[0].range]), "Alice")
    }

    // MARK: - Every term, every match, diacritics ignored (vault-browsing-parity)

    func testHighlightedText_everyTermAndDiacritics() {
        let result = ItemRowView.highlightedText("Müller GitHub", query: "muller git")
        let bold = result.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(result.characters[$0.range]) }
        XCTAssertEqual(bold, ["Müller", "Git"])
    }

    // MARK: - A match the row does not show has no highlight (vault-browsing-parity; verify 2026-10-31)

    func testMatchOnlyInHiddenNotes_highlightsNothing() throws {
        let note = VaultItem(id: "n", name: "Shopping", isFavorite: false, isDeleted: false,
                             creationDate: Date(), revisionDate: Date(),
                             content: .secureNote(SecureNoteContent(notes: String(repeating: "x", count: 40) + " zebra",
                                                                    customFields: [])))
        let subtitle = try XCTUnwrap(ItemRowView.subtitle(for: note))
        for text in [note.name, subtitle] {
            let result = ItemRowView.highlightedText(text, query: "zebra")
            XCTAssertTrue(result.runs.allSatisfy { $0.inlinePresentationIntent == nil }, text)
        }
    }

    // MARK: - Empty query returns plain

    func testHighlightedText_emptyQuery_returnsPlain() {
        let result = ItemRowView.highlightedText("Hello World", query: "")
        let runs = Array(result.runs)
        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs[0].attributes.inlinePresentationIntent)
    }
}
