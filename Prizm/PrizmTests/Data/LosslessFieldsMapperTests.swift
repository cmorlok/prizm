import XCTest
@testable import Prizm

/// Values Prizm reads into its Domain model go back to the server unchanged unless the user edits
/// them (openspec change `fix-read-mapping-lossless-fields`): custom fields without a name, websites
/// without an address, and field types, linked ids and match rules Prizm does not know. Real crypto
/// throughout; the stored record is built as JSON, which is how such entries reach the app.
@MainActor
final class LosslessFieldsMapperTests: XCTestCase {

    private let mapper = CipherMapper()
    private let keys = KeyedCipherBuilder.randomKeys()
    private let storedChecksum = "2.orphanChecksum|kept|as-received"

    // MARK: - Fixture

    private func enc(_ plaintext: String) -> String {
        KeyedCipherBuilder.encrypt(plaintext, keys: keys)
    }

    private func dec(_ encString: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let string = try XCTUnwrap(encString as? String, "not an EncString", file: file, line: line)
        let data = try EncString(string: string).decrypt(keys: keys)
        return try XCTUnwrap(String(data: data, encoding: .utf8), file: file, line: line)
    }

    /// A login whose websites and custom fields hold every case the read path used to drop or
    /// change (task 1.1). The nameless field and the value-less website also carry a key Prizm does
    /// not know, so the pairing of design D4 is visible.
    private func storedRecord() throws -> RawCipher {
        let json: [String: Any] = [
            "id": "item-1",
            "type": 1,
            "name": enc("Lossless"),
            "favorite": false,
            "reprompt": 0,
            "revisionDate": RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
            "creationDate": RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
            "login": [
                "username": enc("user"),
                "password": enc("pw"),
                "uris": [
                    ["uri": NSNull(), "match": 3, "uriChecksum": storedChecksum, "x-uri-extra": "nil-uri"],
                    ["uri": enc("https://a.example.com"), "match": 7,
                     "uriChecksum": enc(CipherMapper.uriChecksumPlaintext("https://a.example.com"))],
                ],
            ],
            "fields": [
                ["type": 0, "name": NSNull(), "value": enc("abc"), "x-field-extra": "nameless"],
                ["type": 9, "name": enc("Future"), "value": enc("v9")],
                ["type": 3, "name": enc("Link"), "value": NSNull(), "linkedId": 999],
            ],
        ]
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Maps the stored record, changes only the username (as the edit sheet would), and builds the
    /// update request over the stored record.
    private func saveWithNewUsername() throws -> (request: RawCipher, json: [String: Any]) {
        let record = try storedRecord()
        var draft = DraftVaultItem(try mapper.map(raw: record, vaultKeys: keys).item)
        guard case .login(var login) = draft.content else { throw XCTSkip("fixture is not a login") }
        login.username = "user2"
        draft.content = .login(login)
        let request = try mapper.toRawCipher(draft.normalisedForSave(currentYear: 2026), overlaying: record,
                                             effectiveKeys: keys, encryptedFor: RepositoryFixtures.profileId)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        return (request, json)
    }

    // MARK: - Read

    func testRead_keepsNamelessFieldValueLessWebsiteAndUnknownValues() throws {
        let item = try mapper.map(raw: try storedRecord(), vaultKeys: keys).item
        guard case .login(let login) = item.content else { return XCTFail("not a login") }

        XCTAssertEqual(login.uris, [
            LoginURI(uri: nil, matchType: .exact),
            LoginURI(uri: "https://a.example.com", matchType: .unknown(7)),
        ])
        XCTAssertEqual(login.customFields, [
            CustomField(name: nil, value: "abc", type: .text, linkedId: nil),
            CustomField(name: "Future", value: "v9", type: .unknown(9), linkedId: nil),
            CustomField(name: "Link", value: nil, type: .linked, linkedId: .unknown(999)),
        ])
    }

    // MARK: - Save (task 1.2)

    func testSave_sendsNamelessFieldWithNullName() throws {
        let fields = try XCTUnwrap(try saveWithNewUsername().json["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 3)
        XCTAssertTrue(fields[0]["name"] is NSNull,
                      "the name is sent as an explicit null, as the official clients do (live rig 2026-10-30: an absent key is stored absent)")
        XCTAssertEqual(try dec(fields[0]["value"]), "abc")
        XCTAssertEqual(fields[0]["type"] as? Int, 0)
        XCTAssertEqual(fields[0]["x-field-extra"] as? String, "nameless", "unknown keys of the nameless field are kept")
    }

    func testSave_keepsUnknownFieldTypeAndLinkedId() throws {
        let fields = try XCTUnwrap(try saveWithNewUsername().json["fields"] as? [[String: Any]])
        XCTAssertEqual(fields[1]["type"] as? Int, 9)
        XCTAssertEqual(try dec(fields[1]["name"]), "Future")
        XCTAssertEqual(try dec(fields[1]["value"]), "v9")
        XCTAssertEqual(fields[2]["type"] as? Int, 3)
        XCTAssertEqual(fields[2]["linkedId"] as? Int, 999)
    }

    func testSave_sendsValueLessWebsiteWithNullUriAndStoredChecksum() throws {
        let login = try XCTUnwrap(try saveWithNewUsername().json["login"] as? [String: Any])
        let uris = try XCTUnwrap(login["uris"] as? [[String: Any]])
        XCTAssertEqual(uris.count, 2, "the value-less website is not dropped")
        XCTAssertTrue(uris[0]["uri"] is NSNull, "the address is sent as an explicit null, as the official clients do")
        XCTAssertEqual(uris[0]["match"] as? Int, 3)
        XCTAssertEqual(uris[0]["uriChecksum"] as? String, storedChecksum, "no checksum is computed for it")
        XCTAssertEqual(uris[0]["x-uri-extra"] as? String, "nil-uri", "unknown keys of the value-less website are kept")
    }

    func testSave_keepsUnknownMatchRuleAndOrder() throws {
        let login = try XCTUnwrap(try saveWithNewUsername().json["login"] as? [String: Any])
        let uris = try XCTUnwrap(login["uris"] as? [[String: Any]])
        XCTAssertEqual(try dec(uris[1]["uri"]), "https://a.example.com")
        XCTAssertEqual(uris[1]["match"] as? Int, 7)
        XCTAssertEqual(try dec(uris[1]["uriChecksum"]), CipherMapper.uriChecksumPlaintext("https://a.example.com"))
        XCTAssertEqual(try dec(login["username"]), "user2")
    }

    // MARK: - After the save (task 1.3)

    /// The post-save path maps the request again (`VaultRepositoryImpl.update`); every value is
    /// still there.
    func testSavedRequestMapsBackToTheSameValues() throws {
        let original = try mapper.map(raw: try storedRecord(), vaultKeys: keys).item
        let saved = try mapper.map(raw: try saveWithNewUsername().request, vaultKeys: keys).item
        guard case .login(let before) = original.content, case .login(let after) = saved.content else {
            return XCTFail("not a login")
        }
        XCTAssertEqual(after.uris, before.uris)
        XCTAssertEqual(after.customFields, before.customFields)
        XCTAssertEqual(after.username, "user2")
    }

    // MARK: - Filling in a value-less website

    func testFillingInValueLessWebsite_encryptsItWithItsMatchRule() throws {
        let record = try storedRecord()
        var draft = DraftVaultItem(try mapper.map(raw: record, vaultKeys: keys).item)
        guard case .login(var login) = draft.content else { return XCTFail("not a login") }
        login.uris[0].text = "https://new.example"
        draft.content = .login(login)
        let request = try mapper.toRawCipher(draft.normalisedForSave(currentYear: 2026), overlaying: record,
                                             effectiveKeys: keys, encryptedFor: RepositoryFixtures.profileId)
        let uri = try XCTUnwrap(request.login?.uris?.first)
        XCTAssertEqual(try dec(uri.uri), "https://new.example")
        XCTAssertEqual(uri.match, 3)
        XCTAssertEqual(try dec(uri.uriChecksum), CipherMapper.uriChecksumPlaintext("https://new.example"))
    }

    // MARK: - Regression guard (task 3.3)

    /// An item with only known values: same keys in the same order as before this change.
    func testKnownValuesOnly_requestStructureUnchanged() throws {
        let item = VaultItem(
            id: "item-2", name: "Known", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate,
            content: .login(LoginContent(
                username: "u", password: "p",
                uris: [LoginURI(uri: "https://k.example.com", matchType: .host)],
                totp: nil, notes: nil,
                customFields: [CustomField(name: "Pin", value: "1", type: .hidden, linkedId: nil)])))
        let request = try mapper.toNewRawCipher(DraftVaultItem(item), encryptedWith: keys,
                                                encryptedFor: RepositoryFixtures.profileId)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let field = try XCTUnwrap((json["fields"] as? [[String: Any]])?.first)
        // `nil` members are not written (`WireWriter.put`), so `linkedId` is absent.
        XCTAssertEqual(Set(field.keys), ["type", "name", "value"])
        XCTAssertEqual(field["type"] as? Int, 1)
        XCTAssertEqual(try dec(field["name"]), "Pin")
        let uri = try XCTUnwrap(((json["login"] as? [String: Any])?["uris"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(uri.keys), ["uri", "match", "uriChecksum"])
        XCTAssertEqual(uri["match"] as? Int, 1)
    }
}
