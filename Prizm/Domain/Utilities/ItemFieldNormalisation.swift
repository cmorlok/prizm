import Foundation

// MARK: - CardFieldValue

/// A card field as the edit form sees it: empty, one of the official values, or a value another
/// client or an earlier Prizm version stored that matches none of them.
nonisolated enum CardFieldValue: Equatable, Hashable {
    case notSet
    case known(String)
    /// Kept and saved unchanged; clearing it would lose data the user stored on purpose.
    case custom(String)

    /// The string to store, `nil` for `.notSet`.
    var stored: String? {
        switch self {
        case .notSet:            nil
        case .known(let value):  value
        case .custom(let value): value
        }
    }
}

// MARK: - CardBrand

/// The card brands official Bitwarden clients offer, with their stored values.
///
/// Values and order as in the web form (`card-details-section.component.ts` `cardBrands`) and iOS
/// (`CardComponent.Brand`). American Express is stored as "Amex".
nonisolated enum CardBrand {

    // Nested types don't inherit `nonisolated`; the app target defaults to MainActor.
    nonisolated struct Option: Equatable, Hashable {
        let value: String
        let displayName: String
    }

    static let options: [Option] = [
        Option(value: "Visa", displayName: "Visa"),
        Option(value: "Mastercard", displayName: "Mastercard"),
        Option(value: "Amex", displayName: "American Express"),
        Option(value: "Discover", displayName: "Discover"),
        Option(value: "Diners Club", displayName: "Diners Club"),
        Option(value: "JCB", displayName: "JCB"),
        Option(value: "Maestro", displayName: "Maestro"),
        Option(value: "UnionPay", displayName: "UnionPay"),
        Option(value: "RuPay", displayName: "RuPay"),
        Option(value: "Other", displayName: "Other"),
    ]

    /// Short forms people type that are neither a stored value nor a display name.
    private static let aliases: [String: String] = ["diners": "Diners Club"]

    /// Maps a stored brand to the official value it means, ignoring case and surrounding spaces.
    static func canonical(for stored: String?) -> CardFieldValue {
        guard let stored else { return .notSet }
        let key = stored.trimmingCharacters(in: .whitespaces).lowercased()
        if key.isEmpty { return .notSet }
        if let option = options.first(where: { $0.value.lowercased() == key || $0.displayName.lowercased() == key }) {
            return .known(option.value)
        }
        if let value = aliases[key] { return .known(value) }
        return .custom(stored)
    }

    /// The display name for a stored value, or the value itself when it is not an official one.
    static func displayName(for stored: String) -> String {
        options.first { $0.value == stored }?.displayName ?? stored
    }

    /// The brand the official clients detect from a card number, or `nil`.
    ///
    /// A literal port of `CardView.getCardBrandByPatterns` (clients
    /// `libs/common/src/vault/models/view/card.view.ts`): same patterns, same order, applied to the
    /// number as typed. Maestro, UnionPay and RuPay are never detected there either.
    static func detect(number: String?) -> String? {
        guard let number, !number.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        for (pattern, brand) in patterns where number.range(of: pattern, options: .regularExpression) != nil {
            return brand
        }
        return nil
    }

    private static let patterns: [(String, String)] = [
        ("^4", "Visa"),
        // Mastercard 2017 BIN expansion; the whole 16-digit number must match. `\z` stands for the
        // JavaScript `$`: in NSRegularExpression `$` also matches before a trailing newline.
        ("^(5[1-5][0-9]{14}|2(22[1-9][0-9]{12}|2[3-9][0-9]{13}|[3-6][0-9]{14}|7[0-1][0-9]{13}|720[0-9]{12}))\\z", "Mastercard"),
        ("^3[47]", "Amex"),
        ("^(6011|622(12[6-9]|1[3-9][0-9]|[2-8][0-9]{2}|9[0-1][0-9]|92[0-5]|64[4-9])|65)", "Discover"),
        ("^36", "Diners Club"),
        // Carte Blanche
        ("^30[0-5]", "Diners Club"),
        ("^35(2[89]|[3-8][0-9])", "JCB"),
        // Visa Electron; unreachable after "^4" but kept so the list stays a literal port.
        ("^(4026|417500|4508|4844|491(3|7))", "Visa"),
    ]
}

// MARK: - ExpiryMonth

/// Expiry months as official clients store them: "1" to "12", no leading zero.
nonisolated enum ExpiryMonth {

    /// "1" … "12" with the web form's labels "01 - January" … "12 - December".
    static let options: [CardBrand.Option] = (1...12).map {
        CardBrand.Option(value: String($0), displayName: String(format: "%02d - %@", $0, monthNames[$0 - 1]))
    }

    // English like the rest of Prizm's UI, which has no localisation yet.
    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                                     "August", "September", "October", "November", "December"]

    static func canonical(for stored: String?) -> CardFieldValue {
        guard let stored else { return .notSet }
        let trimmed = stored.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .notSet }
        if trimmed.allSatisfy(\.isASCIIDigit), let month = Int(trimmed), (1...12).contains(month) {
            return .known(String(month))
        }
        return .custom(stored)
    }

    static func name(of month: Int) -> String? {
        (1...12).contains(month) ? monthNames[month - 1] : nil
    }
}

// MARK: - ExpiryYear

nonisolated enum ExpiryYear {

    /// Normalises a typed year to four digits, or `nil` when nothing usable is left.
    ///
    /// A port of `normalizeExpiryYearFormat` (clients `libs/common/src/autofill/utils/index.ts`):
    /// a four-digit year starting 1–9 is kept; otherwise non-digits and leading zeros are removed,
    /// and a result that is not four digits becomes the current century plus its last two digits
    /// ("25" → "2025", "125" → "2025"). `currentYear` is passed in so tests don't depend on the clock.
    static func normalised(_ input: String?, currentYear: Int) -> String? {
        guard let input, !input.isEmpty else { return nil }
        if input.count == 4, input.allSatisfy(\.isASCIIDigit), input.first != "0" { return input }

        var digits = String(input.filter(\.isASCIIDigit))
        // Leading zeros go, but a lone "0" stays (the official regex keeps the last character).
        while digits.count > 1, digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { return nil }
        if digits.count == 4 { return digits }

        let century = String(String(currentYear).prefix(2))
        let lastTwo = String(("00" + digits).suffix(2))
        return century + lastTwo
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - CardExpiry

nonisolated enum CardExpiry {

    /// The expiry as shown, "MM / YYYY" when month and year are both numeric (month 1–12, four-digit
    /// year), otherwise the stored values as they are; `spoken` reads the month by name.
    static func display(month: String?, year: String?) -> (text: String, spoken: String?)? {
        let trimmedMonth = month?.trimmingCharacters(in: .whitespaces)
        let trimmedYear = year?.trimmingCharacters(in: .whitespaces)
        if case .known(let value) = ExpiryMonth.canonical(for: trimmedMonth), let number = Int(value),
           let trimmedYear, trimmedYear.count == 4, trimmedYear.allSatisfy(\.isASCIIDigit),
           let name = ExpiryMonth.name(of: number) {
            return (String(format: "%02d / %@", number, trimmedYear), "\(name) \(trimmedYear)")
        }
        let parts = [month, year].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : (parts.joined(separator: "/"), nil)
    }
}

// MARK: - Save-time normalisation

extension DraftCardContent {

    /// Sets the number and, when it matches a known pattern, the brand, as the web form does on
    /// every number change. An existing brand is not touched on load, only when the number is edited.
    nonisolated mutating func setNumber(_ number: String?) {
        self.number = number
        if let detected = CardBrand.detect(number: number) { brand = detected }
    }
}

extension DraftVaultItem {

    /// The draft as it is sent: card brand and expiry in the official format, blank website rows
    /// dropped (openspec change card-field-normalisation).
    ///
    /// - Values that match no official one are kept unchanged, so nothing a user or another client
    ///   stored is lost. A year with no usable digits is kept too, where the web form would clear it.
    /// - A blank website row is dropped instead of being sent as an encrypted empty string, which
    ///   other clients show as an empty "website" row (design D6).
    nonisolated func normalisedForSave(currentYear: Int) -> DraftVaultItem {
        var copy = self
        switch content {
        case .card(var card):
            card.brand = CardBrand.canonical(for: card.brand).stored
            card.expMonth = ExpiryMonth.canonical(for: card.expMonth).stored
            if let year = card.expYear, !year.trimmingCharacters(in: .whitespaces).isEmpty {
                card.expYear = ExpiryYear.normalised(year, currentYear: currentYear) ?? year
            } else {
                card.expYear = nil
            }
            copy.content = .card(card)
        case .login(var login):
            login.uris.removeAll { $0.uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            copy.content = .login(login)
        case .secureNote, .identity, .sshKey:
            break
        }
        return copy
    }
}
