import XCTest
@testable import Prizm

/// Card fields and blank website rows are saved in the format official Bitwarden clients write
/// (openspec change card-field-normalisation).
final class ItemFieldNormalisationTests: XCTestCase {

    // MARK: - 1.1 Brand mapping

    func testBrandCanonical() {
        let cases: [(String?, CardFieldValue)] = [
            (nil, .notSet), ("", .notSet), ("  ", .notSet),
            ("Visa", .known("Visa")), ("visa", .known("Visa")), (" VISA ", .known("Visa")),
            ("Amex", .known("Amex")), ("american express", .known("Amex")),
            ("mastercard", .known("Mastercard")), ("diners", .known("Diners Club")),
            ("Diners Club", .known("Diners Club")), ("other", .known("Other")),
            ("Carte Bleue", .custom("Carte Bleue")),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CardBrand.canonical(for: input), expected, "\(input ?? "nil")")
        }
    }

    func testBrandOptions_matchTheWebForm() {
        XCTAssertEqual(CardBrand.options.map(\.value),
                       ["Visa", "Mastercard", "Amex", "Discover", "Diners Club", "JCB", "Maestro", "UnionPay", "RuPay", "Other"])
        XCTAssertEqual(CardBrand.displayName(for: "Amex"), "American Express")
        XCTAssertEqual(CardBrand.displayName(for: "Carte Bleue"), "Carte Bleue")
    }

    // MARK: - 3.1 Picker entries

    func testPickerChoices_offerACustomEntryOnlyForACustomValue() {
        let official = CardFieldChoice.choices(current: .known("Visa"), options: CardBrand.options)
        XCTAssertEqual(official.first, CardFieldChoice(value: .notSet, title: "Not set"))
        XCTAssertEqual(official.count, 1 + CardBrand.options.count, "No custom entry for an official value")
        XCTAssertEqual(CardFieldChoice.choices(current: .notSet, options: CardBrand.options).count, 1 + CardBrand.options.count)

        let custom = CardFieldChoice.choices(current: .custom("Carte Bleue"), options: CardBrand.options)
        XCTAssertEqual(custom.count, 2 + CardBrand.options.count)
        XCTAssertEqual(custom.last, CardFieldChoice(value: .custom("Carte Bleue"), title: "Carte Bleue (custom)"))
        XCTAssertTrue(custom.contains(CardFieldChoice(value: .known("Amex"), title: "American Express")))
    }

    // MARK: - 1.2 Detection by number (card.view.ts getCardBrandByPatterns)

    func testBrandDetection() {
        let cases: [(String?, String?)] = [
            ("4111111111111111", "Visa"),
            ("4026000000000002", "Visa"),          // Visa Electron, caught by ^4 first
            ("5555555555554444", "Mastercard"),
            ("2221000000000009", "Mastercard"),    // 2017 2-series
            ("2720999999999996", "Mastercard"),
            ("5555 5555 5555 4444", nil),          // the official pattern needs 16 bare digits
            ("5555555555554444\n", nil),           // JavaScript's `$` does not match before a newline
            ("555555555555444", nil),              // 15 digits
            ("378282246310005", "Amex"),
            ("371449635398431", "Amex"),
            ("6011111111111117", "Discover"),
            ("6221260000000000", "Discover"),
            ("36227206271667", "Diners Club"),
            ("30569309025904", "Diners Club"),     // Carte Blanche
            ("3530111333300000", "JCB"),
            ("6759649826438453", nil),             // Maestro is never detected
            ("9999", nil), ("", nil), ("   ", nil), (nil, nil),
        ]
        for (number, expected) in cases {
            XCTAssertEqual(CardBrand.detect(number: number), expected, "\(number ?? "nil")")
        }
    }

    // MARK: - 2.1 Month

    func testMonthCanonical() {
        let cases: [(String?, CardFieldValue)] = [
            ("1", .known("1")), ("01", .known("1")), (" 3 ", .known("3")), ("12", .known("12")),
            ("13", .custom("13")), ("0", .custom("0")), ("Mar", .custom("Mar")), ("", .notSet), (nil, .notSet),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ExpiryMonth.canonical(for: input), expected, "\(input ?? "nil")")
        }
        XCTAssertEqual(ExpiryMonth.options.first?.displayName, "01 - January")
        XCTAssertEqual(ExpiryMonth.options.last?.value, "12")
    }

    // MARK: - 2.2 Year (normalizeExpiryYearFormat)

    func testYearNormalised() {
        let cases: [(String?, String?)] = [
            ("2025", "2025"), ("1999", "1999"), ("25", "2025"), ("5", "2005"), ("0025", "2025"),
            ("125", "2025"), ("12345", "2045"), ("02025", "2025"), ("20 27", "2027"), ("0", "2000"),
            ("", nil), (nil, nil), ("abc", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ExpiryYear.normalised(input, currentYear: 2026), expected, "\(input ?? "nil")")
        }
    }

    // MARK: - 2.4 Detail view (D5)

    func testExpiryDisplay() {
        XCTAssertEqual(CardExpiry.display(month: "3", year: "2027")?.text, "03 / 2027")
        XCTAssertEqual(CardExpiry.display(month: "3", year: "2027")?.spoken, "March 2027")
        XCTAssertEqual(CardExpiry.display(month: "12", year: "2030")?.text, "12 / 2030")
        XCTAssertEqual(CardExpiry.display(month: "Mar", year: "27")?.text, "Mar/27", "Non-numeric: shown as stored")
        XCTAssertNil(CardExpiry.display(month: "Mar", year: "27")?.spoken)
        XCTAssertEqual(CardExpiry.display(month: "3", year: nil)?.text, "3")
        XCTAssertNil(CardExpiry.display(month: nil, year: nil))
    }

    // MARK: - 2.3 Applied on save

    private func card(brand: String? = nil, number: String? = nil, month: String? = nil, year: String? = nil) -> DraftVaultItem {
        var draft = DraftVaultItem.blank(type: .card)
        guard case .card(var c) = draft.content else { fatalError() }
        c.brand = brand; c.number = number; c.expMonth = month; c.expYear = year
        draft.content = .card(c)
        return draft
    }

    private func cardContent(_ draft: DraftVaultItem) -> DraftCardContent? {
        if case .card(let c) = draft.content { return c }
        return nil
    }

    func testSave_normalisesKnownValues() {
        let saved = cardContent(card(brand: "visa", month: "03", year: "27").normalisedForSave(currentYear: 2026))
        XCTAssertEqual(saved?.brand, "Visa")
        XCTAssertEqual(saved?.expMonth, "3")
        XCTAssertEqual(saved?.expYear, "2027")
    }

    func testSave_keepsUnknownValues() {
        let saved = cardContent(card(brand: "Carte Bleue", month: "Mar", year: "n/a").normalisedForSave(currentYear: 2026))
        XCTAssertEqual(saved?.brand, "Carte Bleue")
        XCTAssertEqual(saved?.expMonth, "Mar")
        XCTAssertEqual(saved?.expYear, "n/a", "Nothing usable: kept rather than cleared")
    }

    func testSave_blankFieldsBecomeNil() {
        let saved = cardContent(card(brand: " ", month: "", year: "").normalisedForSave(currentYear: 2026))
        XCTAssertNil(saved?.brand)
        XCTAssertNil(saved?.expMonth)
        XCTAssertNil(saved?.expYear)
    }

    // MARK: - 3.1 Number edits set the brand

    func testSetNumber_setsDetectedBrand_andKeepsItOtherwise() {
        guard var c = cardContent(card(brand: "Other")) else { return XCTFail() }
        c.setNumber("37")
        XCTAssertEqual(c.number, "37")
        XCTAssertEqual(c.brand, "Amex")
        c.setNumber("9")
        XCTAssertEqual(c.brand, "Amex", "No match: the brand stays")
        c.setNumber(nil)
        XCTAssertNil(c.number)
    }

    // MARK: - 4.1 Blank website rows

    private func login(uris: [String]) -> DraftVaultItem {
        var draft = DraftVaultItem.blank(type: .login)
        guard case .login(var l) = draft.content else { fatalError() }
        l.uris = uris.map { DraftLoginURI(uri: $0) }
        draft.content = .login(l)
        return draft
    }

    func testSave_newLoginWithBlankRow_sendsNoURI() {
        guard case .login(let l) = DraftVaultItem.blank(type: .login).normalisedForSave(currentYear: 2026).content
        else { return XCTFail() }
        XCTAssertEqual(l.uris, [])
    }

    func testSave_dropsOnlyBlankRows() {
        guard case .login(let l) = login(uris: ["https://example.com", "  ", ""]).normalisedForSave(currentYear: 2026).content
        else { return XCTFail() }
        XCTAssertEqual(l.uris.map(\.uri), ["https://example.com"])
    }

    func testSave_otherTypesUnchanged() {
        let note = DraftVaultItem.blank(type: .secureNote)
        XCTAssertEqual(note.normalisedForSave(currentYear: 2026), note)
    }
}

/// The edit sheet sends normalised drafts, except for a folder or favorite change only.
@MainActor
final class ItemEditNormalisationTests: XCTestCase {

    private final class Capture: EditVaultItemUseCase, CreateVaultItemUseCase {
        let called: XCTestExpectation
        private(set) var saved: DraftVaultItem?
        init(called: XCTestExpectation) { self.called = called }
        func execute(draft: DraftVaultItem) async throws -> VaultItem {
            saved = draft
            called.fulfill()
            return VaultItem(draft)
        }
    }

    private let card = VaultItem(
        id: "card", name: "Card", isFavorite: false, isDeleted: false,
        creationDate: Date(), revisionDate: Date(),
        content: .card(CardContent(cardholderName: "A", brand: "visa", number: nil, expMonth: "03",
                                   expYear: "2027", code: nil, notes: nil, customFields: []))
    )

    private func savedCard(_ capture: Capture) -> DraftCardContent? {
        if case .card(let c) = capture.saved?.content { return c }
        return nil
    }

    func testEditedCard_isNormalised() async {
        let capture = Capture(called: expectation(description: "saved"))
        let viewModel = ItemEditViewModel(item: card, useCase: capture as EditVaultItemUseCase)
        guard case .card(var c) = viewModel.draft.content else { return XCTFail() }
        c.cardholderName = "B"
        viewModel.draft.content = .card(c)

        viewModel.save()
        await fulfillment(of: [capture.called], timeout: 5)

        XCTAssertEqual(savedCard(capture)?.brand, "Visa")
        XCTAssertEqual(savedCard(capture)?.expMonth, "3")
    }

    func testRenamedCard_isNormalised() async {
        let capture = Capture(called: expectation(description: "saved"))
        let viewModel = ItemEditViewModel(item: card, useCase: capture as EditVaultItemUseCase)
        viewModel.draft.name = "Renamed"

        viewModel.save()
        await fulfillment(of: [capture.called], timeout: 5)

        XCTAssertEqual(savedCard(capture)?.brand, "Visa", "A full PUT follows, so the content is normalised")
    }

    func testFolderOnlyChange_isSentUnchanged() async {
        let capture = Capture(called: expectation(description: "saved"))
        let viewModel = ItemEditViewModel(item: card, useCase: capture as EditVaultItemUseCase,
                                          folders: [Folder(id: "f1", name: "Work")])
        viewModel.draft.folderId = "f1"

        viewModel.save()
        await fulfillment(of: [capture.called], timeout: 5)

        XCTAssertEqual(savedCard(capture)?.brand, "visa", "Content untouched, so the save can use /partial")
        XCTAssertEqual(capture.saved?.folderId, "f1")
    }

    func testNewLoginWithBlankWebsite_sendsNoURI() async {
        let capture = Capture(called: expectation(description: "saved"))
        let viewModel = ItemEditViewModel(type: .login, useCase: capture as CreateVaultItemUseCase)
        viewModel.draft.name = "Login"

        viewModel.save()
        await fulfillment(of: [capture.called], timeout: 5)

        guard case .login(let l) = capture.saved?.content else { return XCTFail() }
        XCTAssertEqual(l.uris, [])
    }
}
