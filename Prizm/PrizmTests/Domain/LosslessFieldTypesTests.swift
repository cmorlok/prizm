import XCTest
@testable import Prizm

/// Domain side of `fix-read-mapping-lossless-fields`: the three server enums keep values Prizm does
/// not know, and a website read without an address stays without one through the edit sheet.
final class LosslessFieldTypesTests: XCTestCase {

    // MARK: - Enums (task 2.2)

    func testCustomFieldType_rawValuesRoundTrip() {
        for raw in 0...3 {
            XCTAssertEqual(CustomFieldType(rawValue: raw).rawValue, raw)
        }
        XCTAssertEqual(CustomFieldType(rawValue: 1), .hidden)
        XCTAssertEqual(CustomFieldType(rawValue: 9), .unknown(9))
        XCTAssertEqual(CustomFieldType.unknown(9).rawValue, 9)
    }

    func testLinkedFieldId_rawValuesRoundTrip() {
        let known = Array(100...101) + Array(300...305) + Array(400...418)
        for raw in known {
            let id = LinkedFieldId(rawValue: raw)
            // Pattern, not `==`: the standard library's `==` for `RawRepresentable` compares raw
            // values, so `.loginUsername == .unknown(100)` holds.
            if case .unknown = id { XCTFail("\(raw) is a known linked id") }
            XCTAssertEqual(id.rawValue, raw)
        }
        XCTAssertEqual(LinkedFieldId(rawValue: 418), .identityFullName)
        XCTAssertEqual(LinkedFieldId(rawValue: 999), .unknown(999))
        XCTAssertEqual(LinkedFieldId.unknown(999).rawValue, 999)
        XCTAssertEqual(LinkedFieldId.unknown(999).displayName, "Unknown field")
    }

    func testURIMatchType_rawValuesRoundTrip() {
        for raw in 0...5 {
            XCTAssertEqual(URIMatchType(rawValue: raw).rawValue, raw)
        }
        XCTAssertEqual(URIMatchType(rawValue: 4), .regularExpression)
        XCTAssertEqual(URIMatchType(rawValue: 7), .unknown(7))
        XCTAssertEqual(URIMatchType.unknown(7).rawValue, 7)
    }

    // MARK: - Value-less websites in the edit sheet (tasks 2.1, 2.3)

    private func draft(uris: [LoginURI]) -> DraftVaultItem {
        DraftVaultItem(VaultItem(
            id: "1", name: "L", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .login(LoginContent(username: nil, password: nil, uris: uris,
                                         totp: nil, notes: nil, customFields: []))))
    }

    private func uris(of draft: DraftVaultItem) -> [DraftLoginURI] {
        guard case .login(let login) = draft.content else { return [] }
        return login.uris
    }

    func testValueLessWebsite_staysNilWhenTypedIntoAndCleared() {
        var uri = DraftLoginURI(LoginURI(uri: nil, matchType: .exact))
        XCTAssertEqual(uri.text, "")
        uri.text = "a"
        XCTAssertEqual(uri.uri, "a")
        uri.text = ""
        XCTAssertNil(uri.uri, "a website read without an address goes back without one")
    }

    func testNewWebsiteRow_isEmptyStringNotNil() {
        var uri = DraftLoginURI()
        XCTAssertEqual(uri.uri, "")
        uri.text = "a"
        uri.text = ""
        XCTAssertEqual(uri.uri, "")
    }

    func testNormalisedForSave_keepsValueLessWebsiteDropsBlankNewRow() {
        var d = draft(uris: [LoginURI(uri: nil, matchType: .exact),
                             LoginURI(uri: "https://a.example.com", matchType: nil)])
        guard case .login(var login) = d.content else { return XCTFail("not a login") }
        login.uris.append(DraftLoginURI(uri: "  "))
        d.content = .login(login)

        let saved = uris(of: d.normalisedForSave(currentYear: 2026))
        XCTAssertEqual(saved.map(\.uri), [nil, "https://a.example.com"])
        XCTAssertEqual(saved.first?.matchType, .exact)
    }

    func testDraftRoundTrip_keepsNilNameAndNilUri() {
        let item = VaultItem(
            id: "1", name: "L", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .login(LoginContent(
                username: nil, password: nil,
                uris: [LoginURI(uri: nil, matchType: .unknown(7))],
                totp: nil, notes: nil,
                customFields: [CustomField(name: nil, value: "x", type: .unknown(9), linkedId: .unknown(999))])))
        XCTAssertEqual(VaultItem(DraftVaultItem(item)).content, item.content)
    }

    // MARK: - Search (task 4.4)

    @MainActor
    func testSearch_skipsValueLessWebsite() async throws {
        let item = VaultItem(
            id: "1", name: "Item", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .login(LoginContent(
                username: nil, password: nil,
                uris: [LoginURI(uri: nil, matchType: nil), LoginURI(uri: "https://find.me", matchType: nil)],
                totp: nil, notes: nil, customFields: [])))
        let vault = await RepositoryFixtures.vaultRepository(apiClient: MockPrizmAPIClient(), crypto: MockPrizmCryptoService())
        await vault.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
        let search = SearchVaultUseCaseImpl(vault: vault)
        let found = try await search.execute(query: "find.me", in: .allItems)
        XCTAssertEqual(found.map(\.id), ["1"])
        let none = try await search.execute(query: "nothing", in: .allItems)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Launch

    func testLaunchPolicy_valueLessWebsiteHasNoURL() {
        XCTAssertNil(URILaunchPolicy.launchURL(for: LoginURI(uri: nil, matchType: nil)))
    }
}
