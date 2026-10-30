import Foundation

/// Search matching and highlight ranges for the item list (openspec change `vault-browsing-parity`,
/// design D2).
///
/// Like the official clients' basic search (`search.service.ts`), the query is split into terms
/// and every term must occur in at least one target, ignoring case and diacritics. Matching and
/// highlighting use the same `range(of:options:locale:)` call on the original text, so they never
/// disagree and ranges never point past a character whose folded form is longer (ß → ss). For
/// speed, the list filter compares folded copies (`searchKey(of:)`, `fold(_:)`).
///
/// Targets: name and notes of every item; username and every website (full address) of a login;
/// cardholder, brand and the last four digits of a card number (never the full number or the code);
/// first and last name, email and company of an identity; the fingerprint of an SSH key. Passwords,
/// custom fields and keys are never searched.
nonisolated enum VaultSearchMatcher {

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// True when every term of `query` occurs in a target of `item`; an empty query matches all.
    static func matches(_ item: VaultItem, query: String) -> Bool {
        matches(searchKey: searchKey(of: item), foldedTerms: terms(query).map(fold))
    }

    /// The same test against targets folded in advance (`searchKey(of:)`), which the repository
    /// keeps per item: folding every target on every keystroke took about 70 ms for 5,000 items.
    static func matches(searchKey: [String], foldedTerms: [String]) -> Bool {
        foldedTerms.allSatisfy { term in searchKey.contains { $0.contains(term) } }
    }

    /// The item's targets, case and diacritics folded.
    static func searchKey(of item: VaultItem) -> [String] {
        targets(of: item).map(fold)
    }

    /// Case and diacritic folding, the same for targets and terms.
    static func fold(_ text: String) -> String {
        text.folding(options: options, locale: .current)
    }

    /// Every occurrence of every term of `query` in `text`, for bold highlighting.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms(query) {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: options, range: searchStart..<text.endIndex, locale: .current) {
                found.append(range)
                searchStart = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func targets(of item: VaultItem) -> [String] {
        var targets = [item.name]
        switch item.content {
        case .login(let login):
            targets += [login.notes, login.username].compactMap { $0 }
            targets += login.uris.compactMap(\.uri)
        case .card(let card):
            targets += [card.notes, card.cardholderName, card.brand].compactMap { $0 }
            if let number = card.number, let lastFour = lastFourDigits(of: number) {
                targets.append(lastFour)
            }
        case .identity(let identity):
            targets += [identity.notes, identity.firstName, identity.lastName, identity.email, identity.company]
                .compactMap { $0 }
        case .secureNote(let note):
            targets += [note.notes].compactMap { $0 }
        case .sshKey(let key):
            targets += [key.notes, key.keyFingerprint].compactMap { $0 }
        }
        return targets
    }
}

nonisolated extension VaultSearchMatcher {
    /// The last four digits of a card number, spaces and dashes skipped; nil with fewer than four.
    /// The list row shows the same four, so a match is always highlighted.
    static func lastFourDigits(of number: String) -> String? {
        let digits = number.filter(\.isNumber)
        return digits.count >= 4 ? String(digits.suffix(4)) : nil
    }
}

/// The order of every list and tree (openspec change `vault-browsing-parity`, design D5):
/// Finder-style natural order (numeric, locale-aware), as the official clients' `Intl.Collator`
/// with `numeric: true`.
nonisolated enum VaultSort {

    static func ascending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    /// Items by name, then by username (a login without one and every other type count as ""),
    /// then in their order in `items` (sync order). Every item has all three keys, so the order is
    /// consistent whatever the types (a tie-break for logins only would not be transitive).
    static func items(_ items: [VaultItem]) -> [VaultItem] {
        items.enumerated().sorted { lhs, rhs in
            let byName = lhs.element.name.localizedStandardCompare(rhs.element.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            let byUser = username(lhs.element).localizedStandardCompare(username(rhs.element))
            if byUser != .orderedSame { return byUser == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func username(_ item: VaultItem) -> String {
        if case .login(let login) = item.content { return login.username ?? "" }
        return ""
    }
}
