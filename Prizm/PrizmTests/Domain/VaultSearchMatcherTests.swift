import XCTest
@testable import Prizm

/// Search matching and highlight ranges (openspec change `vault-browsing-parity`, tasks 1.1 and 1.3).
final class VaultSearchMatcherTests: XCTestCase {

    private func item(_ content: ItemContent, name: String = "Item") -> VaultItem {
        VaultItem(id: UUID().uuidString, name: name, isFavorite: false, isDeleted: false,
                  creationDate: Date(), revisionDate: Date(), content: content)
    }

    private func login(name: String = "GitHub", username: String? = "alice@work.example",
                       uris: [String] = [], notes: String? = nil) -> VaultItem {
        item(.login(LoginContent(username: username, password: "p", uris: uris.map { LoginURI(uri: $0, matchType: nil) },
                                 totp: nil, notes: notes, customFields: [])), name: name)
    }

    private func matches(_ item: VaultItem, _ query: String) -> Bool { VaultSearchMatcher.matches(item, query: query) }

    func testTerms_splitOnWhitespace() {
        XCTAssertEqual(VaultSearchMatcher.terms("  github   work \n"), ["github", "work"])
        XCTAssertEqual(VaultSearchMatcher.terms(""), [])
    }

    func testEveryTermMustMatchSomeTarget() {
        XCTAssertTrue(matches(login(), "github work"), "name and username")
        XCTAssertFalse(matches(login(), "github home"))
        XCTAssertTrue(matches(login(), ""), "empty query matches all")
    }

    func testCaseAndDiacriticsIgnored() {
        let identity = item(.identity(IdentityContent(
            title: nil, firstName: "Jörg", middleName: nil, lastName: "Müller", address1: nil, address2: nil,
            address3: nil, city: nil, state: nil, postalCode: nil, country: nil, company: "Acme",
            email: "j@example.com", phone: nil, ssn: nil, username: nil, passportNumber: nil,
            licenseNumber: nil, notes: nil, customFields: [])))
        XCTAssertTrue(matches(identity, "muller"))
        XCTAssertTrue(matches(identity, "JORG acme"))
        XCTAssertTrue(matches(identity, "j@example"))
        XCTAssertTrue(matches(identity, "Müller"))
    }

    func testTargetsPerType() {
        XCTAssertTrue(matches(login(uris: ["https://example.com/login"]), "example.com/login"), "full URI")
        XCTAssertTrue(matches(login(notes: "router admin"), "router"), "notes")
        let card = item(.card(CardContent(cardholderName: "Alice", brand: "Visa", number: "4111 1111 1111 4242",
                                          expMonth: nil, expYear: nil, code: "123", notes: nil, customFields: [])))
        XCTAssertTrue(matches(card, "visa"))
        XCTAssertTrue(matches(card, "4242"), "last four digits")
        XCTAssertFalse(matches(card, "4111"), "never the full number")
        XCTAssertFalse(matches(card, "123"), "never the security code")
        let note = item(.secureNote(SecureNoteContent(notes: "top secret", customFields: [])), name: "Note")
        XCTAssertTrue(matches(note, "top"))
        let ssh = item(.sshKey(SSHKeyContent(privateKey: "priv", publicKey: "pub", keyFingerprint: "SHA256:abc",
                                             notes: nil, customFields: [])))
        XCTAssertTrue(matches(ssh, "sha256:abc"), "fingerprint")
        XCTAssertFalse(matches(ssh, "priv"), "never the private key")
    }

    func testPasswordsAreNeverSearched() {
        let withSecret = item(.login(LoginContent(username: "u", password: "zzqq-secret", uris: [], totp: nil,
                                                  notes: nil, customFields: [])))
        XCTAssertFalse(matches(withSecret, "zzqq"))
    }

    // MARK: - Highlight ranges (1.3)

    func testRanges_everyMatchOfEveryTerm_onTheOriginalText() {
        let text = "Müller GitHub git"
        let ranges = VaultSearchMatcher.ranges(of: "muller git", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Müller", "Git", "git"])
    }

    func testRanges_keepOffsetsWhereFoldingWouldChangeLength() {
        let text = "Straße 1"
        let ranges = VaultSearchMatcher.ranges(of: "1", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["1"])
    }
}

/// Task 1.4: a guard against a slow search, with a generous bound; the developer-Mac number is
/// recorded by hand in design.md.
final class VaultSearchMatcherPerformanceTests: XCTestCase {

    func testMatch_fiveThousandItems() {
        let items = (0..<5_000).map { index in
            VaultItem(id: "\(index)", name: "Item \(index) Bank", isFavorite: false, isDeleted: false,
                      creationDate: Date(), revisionDate: Date(),
                      content: .login(LoginContent(username: "user\(index)@example.com", password: "p",
                                                   uris: [LoginURI(uri: "https://site\(index).example.com/login", matchType: nil)],
                                                   totp: nil, notes: "Notes for item \(index)", customFields: [])))
        }
        // As the repository does: folded targets once, then one filter per keystroke.
        let buildStart = Date()
        let keys = items.map(VaultSearchMatcher.searchKey(of:))
        let buildTime = Date().timeIntervalSince(buildStart)
        let terms = VaultSearchMatcher.terms("bank 4999 example").map(VaultSearchMatcher.fold)
        measure {
            _ = keys.filter { VaultSearchMatcher.matches(searchKey: $0, foldedTerms: terms) }
        }
        let start = Date()
        let found = zip(items, keys).filter { VaultSearchMatcher.matches(searchKey: $1, foldedTerms: terms) }
        let filterTime = Date().timeIntervalSince(start)
        print("SEARCH-PERF build \(Int(buildTime * 1000)) ms, filter \(Int(filterTime * 1000)) ms")
        XCTAssertEqual(found.map(\.0.id), ["4999"])
        XCTAssertLessThan(filterTime, 0.5, "far above a frame; something is badly slow")
    }
}
