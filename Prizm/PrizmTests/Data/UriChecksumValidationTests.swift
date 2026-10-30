import XCTest
@testable import Prizm

/// Websites of an item that has its own key are checked against their `uriChecksum` on read, as the
/// Bitwarden SDK does (`cipher.rs` `remove_invalid_checksums`, `login.rs` `is_checksum_valid`); a
/// website that fails is removed and counted (openspec change `uri-checksum-validation`).
///
/// The predicate vectors are the SDK's own (`login.rs` tests); the mapper tests use real crypto.
@MainActor
final class UriChecksumValidationTests: XCTestCase {

    private let mapper = CipherMapper()
    private let vaultKeys = KeyedCipherBuilder.randomKeys()
    private let itemKeys = KeyedCipherBuilder.randomKeys()

    // MARK: - Predicate (task 1.1, design D2)

    func testValidChecksum_sdkVector() {
        XCTAssertTrue(URIChecksum.isValid(uri: "https://example.com",
                                          checksumPlaintext: "EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk="))
    }

    func testWrongChecksum_sdkVector() {
        XCTAssertFalse(URIChecksum.isValid(uri: "https://example.com",
                                           checksumPlaintext: "UtSgIv8LYfEdOu7yqjF7qXWhmouYGYC8RSr7/ryZg5Q="))
    }

    func testMissingChecksumOrURI_isInvalid() {
        XCTAssertFalse(URIChecksum.isValid(uri: "https://example.com", checksumPlaintext: nil))
        XCTAssertFalse(URIChecksum.isValid(uri: nil, checksumPlaintext: "EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk="))
    }

    func testEmptyURI_matchesTheHashOfNothing() {
        XCTAssertTrue(URIChecksum.isValid(uri: "", checksumPlaintext: "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="))
    }

    func testNonBase64Checksum_isInvalid() {
        XCTAssertFalse(URIChecksum.isValid(uri: "https://example.com", checksumPlaintext: "not base64!"))
        // Padding is required (standard alphabet, RFC 4648 section 4), as in the SDK.
        XCTAssertFalse(URIChecksum.isValid(uri: "https://example.com",
                                           checksumPlaintext: "EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk"))
    }

    func testNonCanonicalBase64_isInvalid() {
        // Same bytes as the SDK vector, but the unused low bits of the last character are set
        // ("l" instead of "k"); the SDK's standard base64 engine refuses that spelling.
        XCTAssertFalse(URIChecksum.isValid(uri: "https://example.com",
                                           checksumPlaintext: "EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOl="))
    }

    func testNonASCIIURI_hashesItsUTF8Bytes() {
        XCTAssertTrue(URIChecksum.isValid(uri: "https://exämple.com",
                                          checksumPlaintext: "FxOrK5bfYfzD4fBxUJrbg5lEUQwRt+AmBQr/z0KdUqg="))
    }

    // MARK: - Fixture

    /// A login with four websites (task 1.2): a valid one, one whose checksum is the hash of another
    /// address, one without a checksum, and one without an address. `keyed` gives it its own key.
    /// `firstChecksum` replaces the valid website's checksum.
    private func login(keyed: Bool, firstChecksum: String? = nil) throws -> RawCipher {
        let fieldKeys = keyed ? itemKeys : vaultKeys
        func enc(_ s: String) -> String { KeyedCipherBuilder.encrypt(s, keys: fieldKeys) }
        var json: [String: Any] = [
            "id": "item-1", "type": 1, "name": enc("Checked"), "favorite": false, "reprompt": 0,
            "revisionDate": RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
            "creationDate": RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
            "login": [
                "username": enc("user"),
                "uris": [
                    ["uri": enc("https://good.example"), "match": NSNull(),
                     "uriChecksum": firstChecksum ?? enc(CipherMapper.uriChecksumPlaintext("https://good.example"))],
                    ["uri": enc("https://example.com"), "match": NSNull(),
                     "uriChecksum": enc(CipherMapper.uriChecksumPlaintext("https://evil.example"))],
                    ["uri": enc("https://nochecksum.example"), "match": NSNull()],
                    ["uri": NSNull(), "match": 3],
                ],
            ],
        ]
        if keyed {
            json["key"] = try EncString.encrypt(data: itemKeys.toData(), keys: vaultKeys).toString()
        }
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func loginContent(_ raw: RawCipher) throws -> LoginContent {
        let item = try mapper.map(raw: raw, vaultKeys: vaultKeys).item
        guard case .login(let login) = item.content else { throw XCTSkip("fixture is not a login") }
        return login
    }

    // MARK: - Read (tasks 1.2, 1.3)

    func testKeyedLogin_keepsOnlyTheValidWebsite_andCountsTheOthers() throws {
        let login = try loginContent(try login(keyed: true))
        XCTAssertEqual(login.uris, [LoginURI(uri: "https://good.example", matchType: nil)])
        XCTAssertEqual(login.hiddenURICount, 3)
    }

    func testUnkeyedLogin_keepsEveryWebsite() throws {
        let login = try loginContent(try login(keyed: false))
        XCTAssertEqual(login.uris.map(\.uri),
                       ["https://good.example", "https://example.com", "https://nochecksum.example", nil])
        XCTAssertEqual(login.hiddenURICount, 0)
    }

    func testChecksumThatDoesNotDecrypt_hidesTheWebsite_notTheItem() throws {
        // A well-formed EncString under another key: its MAC fails.
        let foreign = KeyedCipherBuilder.encrypt(CipherMapper.uriChecksumPlaintext("https://good.example"),
                                                 keys: KeyedCipherBuilder.randomKeys())
        let login = try loginContent(try login(keyed: true, firstChecksum: foreign))
        XCTAssertEqual(login.uris, [])
        XCTAssertEqual(login.hiddenURICount, 4)
    }

    func testFavoriteAndCopyWebsiteSeeOnlyKeptWebsites() throws {
        let login = try loginContent(try login(keyed: true))
        XCTAssertEqual(login.firstAddress, "https://good.example")
        XCTAssertEqual(login.addressedURIs.map(\.uri), ["https://good.example"])
    }

    func testSearchDoesNotFindTheItemThroughAHiddenWebsite() async throws {
        let item = try mapper.map(raw: try login(keyed: true), vaultKeys: vaultKeys).item
        let vault = await RepositoryFixtures.vaultRepository(apiClient: MockPrizmAPIClient(),
                                                             crypto: MockPrizmCryptoService())
        await vault.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
        let viaHidden = try await vault.searchItems(query: "example.com", in: .allItems)
        let viaMissing = try await vault.searchItems(query: "nochecksum", in: .allItems)
        let viaKept = try await vault.searchItems(query: "good.example", in: .allItems)
        XCTAssertTrue(viaHidden.isEmpty)
        XCTAssertTrue(viaMissing.isEmpty)
        XCTAssertEqual(viaKept.map(\.id), ["item-1"])
    }

    // MARK: - Save (task 2.3, design D5)

    func testEditAfterRemoval_sendsOnlyTheKeptWebsiteWithAFreshChecksum() throws {
        let record = try login(keyed: true)
        let effective = try mapper.effectiveKeys(for: record, activeKeys: vaultKeys)
        var draft = DraftVaultItem(try mapper.map(raw: record, vaultKeys: vaultKeys).item)
        guard case .login(var content) = draft.content else { return XCTFail("not a login") }
        content.username = "user2"
        draft.content = .login(content)

        let request = try mapper.toRawCipher(draft.normalisedForSave(currentYear: 2026), overlaying: record,
                                             effectiveKeys: effective, encryptedFor: RepositoryFixtures.profileId)

        let uris = try XCTUnwrap(request.login?.uris)
        XCTAssertEqual(uris.count, 1)
        let address = try decrypt(uris[0].uri, keys: itemKeys)
        XCTAssertEqual(address, "https://good.example")
        XCTAssertEqual(try decrypt(uris[0].uriChecksum, keys: itemKeys), CipherMapper.uriChecksumPlaintext(address))
        // Mapping the request again, as the post-save path does, leaves nothing hidden.
        XCTAssertEqual(try loginContent(request).hiddenURICount, 0)
    }

    func testSave_aHiddenWebsiteGivesNothingToAShownOneWithTheSameText() throws {
        func enc(_ s: String) -> String { KeyedCipherBuilder.encrypt(s, keys: itemKeys) }
        let json: [String: Any] = [
            "id": "item-1", "type": 1, "name": enc("Twins"), "favorite": false, "reprompt": 0,
            "revisionDate": RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
            "creationDate": RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
            "key": try EncString.encrypt(data: itemKeys.toData(), keys: vaultKeys).toString(),
            "login": [
                "uris": [
                    // Hidden: its checksum is another address's. Its unknown key must not travel.
                    ["uri": enc("https://dup.example"), "match": NSNull(), "tag": "from-hidden",
                     "uriChecksum": enc(CipherMapper.uriChecksumPlaintext("https://evil.example"))],
                    ["uri": enc("https://dup.example"), "match": NSNull(), "tag": "from-shown",
                     "uriChecksum": enc(CipherMapper.uriChecksumPlaintext("https://dup.example"))],
                ],
            ],
        ]
        let record = try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
        let effective = try mapper.effectiveKeys(for: record, activeKeys: vaultKeys)
        let draft = DraftVaultItem(try mapper.map(raw: record, vaultKeys: vaultKeys).item)

        let request = try mapper.toRawCipher(draft, overlaying: record,
                                             effectiveKeys: effective, encryptedFor: RepositoryFixtures.profileId)

        let uris = try XCTUnwrap(request.login?.uris)
        XCTAssertEqual(uris.count, 1)
        XCTAssertEqual(uris[0].extras["tag"], .string("from-shown"))
    }

    // MARK: - Detail (design D4)

    func testWebsitesCard_isShownWhenEveryWebsiteWasHidden() {
        XCTAssertTrue(LoginDetailView.showsWebsitesCard(addressedCount: 0, hiddenCount: 2),
                      "the card holds only the notice")
        XCTAssertTrue(LoginDetailView.showsWebsitesCard(addressedCount: 1, hiddenCount: 0))
        XCTAssertFalse(LoginDetailView.showsWebsitesCard(addressedCount: 0, hiddenCount: 0))
    }

    func testKeyedLoginWhoseEveryWebsiteFails_showsNoneAndCountsThem() throws {
        let login = try loginContent(try login(keyed: true, firstChecksum: KeyedCipherBuilder.encrypt(
            CipherMapper.uriChecksumPlaintext("https://other.example"), keys: itemKeys)))
        XCTAssertTrue(login.addressedURIs.isEmpty)
        XCTAssertEqual(login.hiddenURICount, 4)
        XCTAssertTrue(LoginDetailView.showsWebsitesCard(addressedCount: login.addressedURIs.count,
                                                        hiddenCount: login.hiddenURICount))
    }

    private func decrypt(_ encString: String?, keys: CryptoKeys,
                         file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let wire = try XCTUnwrap(encString, "missing EncString", file: file, line: line)
        let data = try EncString(string: wire).decrypt(keys: keys)
        return try XCTUnwrap(String(data: data, encoding: .utf8), file: file, line: line)
    }
}
