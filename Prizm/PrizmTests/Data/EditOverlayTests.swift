import XCTest
@testable import Prizm

/// A save is built over the item's last server record: the draft owns what the edit sheet shows,
/// the stored record supplies the rest (item key, passkeys, password history, archived state, the
/// SSH key fingerprint and every key Prizm does not know), and every edited field is encrypted with
/// the key the server expects for the item. Real crypto and the real API client throughout; the
/// golden fixture was written by the browser extension on Vaultwarden 1.37.4.
///
/// Preserved values are compared as `JSONValue` (never through `JSONSerialization`, which bridges
/// `true` to `1`); fields that are re-encrypted are compared by their decrypted plaintext, because
/// every save uses fresh IVs.
@MainActor
final class EditOverlayTests: XCTestCase {

    private let mapper = CipherMapper()
    private let vaultKeys = KeyedCipherBuilder.randomKeys()

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - Helpers

    private func makeClient() async -> PrizmAPIClientImpl {
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        await client.setAccessToken("token")
        return client
    }

    private struct SyncRig {
        let sync: SyncRepositoryImpl
        let vault: VaultRepositoryImpl
        let store: RawCipherStore
    }

    /// Real client (answering `body` to the sync GET and echoing every other request body), real
    /// crypto service unlocked with the golden vault key, one `OrgKeyCache`, one profile id holder and
    /// one `RawCipherStore` shared by the vault and sync repositories, as `AppContainer` wires them.
    private func makeSyncRig(golden: GoldenVault.Snapshot, body: Data) async -> SyncRig {
        let client = await makeClient()
        let crypto = PrizmCryptoServiceImpl()
        await crypto.unlockWith(keys: golden.vaultKeys)
        let profileIds = await RepositoryFixtures.profileIds(seededWith: nil)
        let orgKeyCache = OrgKeyCache()
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: client, crypto: crypto, orgKeyCache: orgKeyCache, profileIds: profileIds, recordStore: store
        )
        let sync = await RepositoryFixtures.syncRepository(
            apiClient: client, crypto: crypto, vaultRepository: vault,
            vaultKeyCache: VaultKeyCache(), orgKeyCache: orgKeyCache, profileIds: profileIds, recordStore: store
        )
        StubURLProtocol.responder = { request in
            if request.httpMethod == "GET" { return .status(200, body: body) }
            // The echo decrypts with the item's key, so update() can map it.
            return .status(200, body: StubURLProtocol.requests.last?.body ?? Data())
        }
        return SyncRig(sync: sync, vault: vault, store: store)
    }

    /// The request body of the last recorded request as `JSONValue`.
    private func lastBody(file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        let body = try XCTUnwrap(StubURLProtocol.requests.last?.body, "no request body", file: file, line: line)
        return try JSONDecoder().decode(JSONValue.self, from: body)
    }

    /// A fixture that does not hold what the tests expect. It fails the test: a skip would leave the
    /// round trip unchecked without anything turning red.
    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    /// The golden cipher `id` as `JSONValue`, straight from the fixture bytes.
    private func goldenJSON(_ id: String, golden: GoldenVault.Snapshot) throws -> JSONValue {
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: golden.rawJSON),
              case .array(let ciphers)? = root["ciphers"] else {
            throw FixtureError(description: "the fixture has no ciphers array")
        }
        for cipher in ciphers {
            if case .object(let members) = cipher, members["id"] == .string(id) { return cipher }
        }
        throw FixtureError(description: "the fixture has no cipher \(id)")
    }

    private func decrypt(_ encString: String?, keys: CryptoKeys,
                         file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let wire = try XCTUnwrap(encString, "missing EncString", file: file, line: line)
        let data = try EncString(string: wire).decrypt(keys: keys)
        return try XCTUnwrap(String(data: data, encoding: .utf8), file: file, line: line)
    }

    private func decryptJSON(_ value: JSONValue?, keys: CryptoKeys,
                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard case .string(let wire)? = value else {
            XCTFail("expected an EncString", file: file, line: line)
            throw CocoaError(.coderInvalidValue)
        }
        return try decrypt(wire, keys: keys, file: file, line: line)
    }

    // MARK: - Tracer: sync the fixture over the real client, edit the keyed passkey login

    func testEditingTheFixturePasskeyLogin_putBodyKeepsItsKeyAndPasskey() async throws {
        let golden = try await GoldenVault.load()
        let rig = await makeSyncRig(golden: golden, body: golden.rawJSON)
        _ = try await rig.sync.sync(progress: { _ in })

        let item = try await rig.vault.itemDetail(id: GoldenVault.passkeyId)
        var draft = DraftVaultItem(item)
        guard case .login(var login) = draft.content else { return XCTFail("not a login") }
        login.username = "edited-user@example.com"
        draft.content = .login(login)

        let saved = try await rig.vault.update(draft)

        let put = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(put.method, "PUT")
        XCTAssertEqual(put.url?.path, "/api/ciphers/\(GoldenVault.passkeyId)")

        let sent = try lastBody()
        let golden3 = try goldenJSON(GoldenVault.passkeyId, golden: golden)
        guard case .object(let sentMembers) = sent, case .object(let goldenMembers) = golden3,
              case .object(let sentLogin)? = sentMembers["login"],
              case .object(let goldenLogin)? = goldenMembers["login"] else {
            return XCTFail("unexpected body shape")
        }

        // The item key travels byte for byte.
        XCTAssertEqual(sentMembers["key"], goldenMembers["key"])
        XCTAssertNotNil(sentMembers["key"])
        // Passkeys and password history are sent as received, `response: null` included.
        XCTAssertEqual(sentLogin["fido2Credentials"], goldenLogin["fido2Credentials"])
        XCTAssertEqual(sentMembers["passwordHistory"], goldenMembers["passwordHistory"])

        // Edited fields decrypt with the item key and not with the vault key.
        let rawGolden = golden.cipher(id: GoldenVault.passkeyId)
        let itemKeys = try mapper.effectiveKeys(for: rawGolden, activeKeys: golden.vaultKeys)
        XCTAssertEqual(try decryptJSON(sentMembers["name"], keys: itemKeys), item.name)
        XCTAssertEqual(try decryptJSON(sentLogin["username"], keys: itemKeys), "edited-user@example.com")
        XCTAssertThrowsError(try decryptJSON(sentMembers["name"], keys: golden.vaultKeys))
        XCTAssertThrowsError(try decryptJSON(sentLogin["username"], keys: golden.vaultKeys))

        // Every website carries a checksum.
        guard case .array(let uris)? = sentLogin["uris"] else { return XCTFail("no uris") }
        XCTAssertEqual(uris.count, 2)
        for uri in uris {
            guard case .object(let members) = uri else { return XCTFail("uri is not an object") }
            XCTAssertNotNil(members["uriChecksum"])
        }

        XCTAssertEqual(sentMembers["encryptedFor"], .string("00000000-0000-4000-8000-000000000010"))

        // The returned item reads under the item key, shows the new username and can be edited again.
        XCTAssertNil(saved.editBlock)
        guard case .login(let savedLogin) = saved.content else { return XCTFail("not a login") }
        XCTAssertEqual(savedLogin.username, "edited-user@example.com")
    }

    // MARK: - Rig with a mock API (preserved-value tests)

    /// A JSON object as `Any`, so a test can edit a record's JSON before it is decoded again. `null`
    /// becomes `NSNull`, which `JSONSerialization` writes as `null`.
    private func plain(_ value: JSONValue) -> Any {
        switch value {
        case .null:             return NSNull()
        case .bool(let v):      return v
        case .int(let v):       return v
        case .double(let v):    return v
        case .string(let v):    return v
        case .array(let v):     return v.map(plain)
        case .object(let v):    return v.mapValues(plain)
        }
    }

    private let sampleFields = [
        CustomField(name: "Field A", value: "a", type: .text, linkedId: nil),
        CustomField(name: "Field B", value: "b", type: .hidden, linkedId: nil),
    ]

    /// One item per cipher type (1 login, 2 secure note, 3 card, 4 identity, 5 SSH key).
    private func sampleItem(_ type: Int, id: String = "item-1") -> VaultItem {
        let content: ItemContent
        switch type {
        case 1:
            content = .login(LoginContent(
                username: "user", password: "pass",
                uris: [LoginURI(uri: "https://a.example.com", matchType: nil), LoginURI(uri: "https://b.example.com", matchType: .host)],
                totp: nil, notes: "notes", customFields: sampleFields))
        case 2:
            content = .secureNote(SecureNoteContent(notes: "note", customFields: sampleFields))
        case 3:
            content = .card(CardContent(
                cardholderName: "Holder", brand: "Visa", number: "4111111111111111", expMonth: "1", expYear: "2030",
                code: "123", notes: nil, customFields: sampleFields))
        case 4:
            content = .identity(IdentityContent(
                title: nil, firstName: "First", middleName: nil, lastName: "Last", address1: nil, address2: nil,
                address3: nil, city: nil, state: nil, postalCode: nil, country: nil, company: nil, email: "e@example.com",
                phone: nil, ssn: nil, username: nil, passportNumber: nil, licenseNumber: nil, notes: nil,
                customFields: sampleFields))
        default:
            content = .sshKey(SSHKeyContent(
                privateKey: "PRIVATE", publicKey: "ssh-ed25519 AAAA", keyFingerprint: nil, notes: nil,
                customFields: sampleFields))
        }
        return VaultItem(
            id: id, name: "Sample \(type)", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate, content: content)
    }

    /// The server's record of `item`: real EncStrings under `keys`, with `edit` applied to its JSON
    /// before it is decoded again, which is how a server record that carries more than Prizm models
    /// reaches the app.
    private func storedRecord(
        for item: VaultItem, keys: CryptoKeys, edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> RawCipher {
        let created = try mapper.toUnkeyedRawCipher(DraftVaultItem(item), encryptedWith: keys, encryptedFor: RepositoryFixtures.profileId)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(created)) as? [String: Any])
        // The create path writes no revision; a server record always has one, and a save needs it.
        json["revisionDate"] = RepositoryFixtures.serverRevisionString(for: item.revisionDate)
        edit(&json)
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// `edit` applied to the nested object `key` of `json`.
    private func nested(_ json: inout [String: Any], _ key: String, _ edit: (inout [String: Any]) -> Void) {
        var object = json[key] as? [String: Any] ?? [:]
        edit(&object)
        json[key] = object
    }

    /// `edit` applied to element `index` of the array `key` of `object`.
    private func element(_ object: inout [String: Any], _ key: String, _ index: Int, _ edit: (inout [String: Any]) -> Void) {
        var array = object[key] as? [[String: Any]] ?? []
        edit(&array[index])
        object[key] = array
    }

    /// Stores `record`, opens its draft as the edit sheet would, applies `edit` (default: a rename)
    /// and saves. Returns the request the repository sent.
    @discardableResult
    private func save(
        _ record: RawCipher, vaultKeys keys: CryptoKeys? = nil, orgKeys: [String: CryptoKeys] = [:],
        file: StaticString = #filePath, line: UInt = #line,
        edit: (inout DraftVaultItem) -> Void = { $0.name = "Edited" }
    ) async throws -> RawCipher {
        let keys = keys ?? vaultKeys
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: keys)
        crypto.stubbedVaultKeys = keys  // unlockWith(keys:) does not set the returned keys
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: orgKeys)
        let store = RawCipherStore()
        let repository = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, recordStore: store)
        let token = await store.currentGeneration()
        await store.upsert(record, ifCurrent: token)

        var draft = DraftVaultItem(try mapper.map(raw: record, vaultKeys: keys, orgKeys: orgKeys).item)
        edit(&draft)
        _ = try await repository.update(draft)
        return try XCTUnwrap(api.lastUpdatedCipher, "no request was sent", file: file, line: line)
    }

    private func encoded(_ cipher: RawCipher) throws -> [String: JSONValue] {
        guard case .object(let members) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cipher)) else {
            throw CocoaError(.coderInvalidValue)
        }
        return members
    }

    // MARK: - Password history (KEEP-02)

    private let oneEntryHistory: JSONValue = .array([
        .object(["password": .string("2.AAAA|BBBB|CCCC"), "lastUsedDate": .string("2026-01-01T00:00:00.000Z")]),
    ])

    func testPasswordHistory_keptOnEveryItemType() async throws {
        for type in 1...5 {
            let record = try storedRecord(for: sampleItem(type), keys: vaultKeys) {
                $0["passwordHistory"] = self.plain(self.oneEntryHistory)
            }

            let sent = try await save(record)

            XCTAssertEqual(sent.passwordHistory, oneEntryHistory, "type \(type)")
        }
    }

    func testPasswordHistory_absentNullAndEmpty_stayAsTheyAre() async throws {
        let variants: [(String, JSONValue?)] = [("absent", nil), ("null", .null), ("empty", .array([]))]
        for type in 1...5 {
            for (label, expected) in variants {
                let record = try storedRecord(for: sampleItem(type), keys: vaultKeys) {
                    if let expected { $0["passwordHistory"] = self.plain(expected) } else { $0.removeValue(forKey: "passwordHistory") }
                }
                XCTAssertEqual(record.passwordHistory, expected, "the stored record is built as \(label)")

                let sent = try await save(record)

                XCTAssertEqual(sent.passwordHistory, expected, "type \(type), \(label)")
                // The wire form too: an absent history must not be written as null, or the reverse.
                XCTAssertEqual(try encoded(sent)["passwordHistory"], expected, "type \(type), \(label) on the wire")
            }
        }
    }

    func testPasswordChange_doesNotAppendToHistory() async throws {
        let record = try storedRecord(for: sampleItem(1), keys: vaultKeys) {
            $0["passwordHistory"] = self.plain(self.oneEntryHistory)
        }

        let sent = try await save(record) { draft in
            guard case .login(var login) = draft.content else { return }
            login.password = "a-completely-new-password"
            draft.content = .login(login)
        }

        // Appending belongs to the password-history change; until then the stored history goes back unchanged.
        XCTAssertEqual(sent.passwordHistory, oneEntryHistory)
        XCTAssertEqual(try decrypt(sent.login?.password, keys: vaultKeys), "a-completely-new-password")
    }

    func testPasswordHistory_entriesKeepTheirOrder() async throws {
        let history: JSONValue = .array([
            .object(["password": .string("2.first|x|y"), "lastUsedDate": .string("2026-01-01T00:00:00.000Z")]),
            .object(["password": .string("2.second|x|y"), "lastUsedDate": .string("2026-02-01T00:00:00.000Z")]),
        ])
        let record = try storedRecord(for: sampleItem(1), keys: vaultKeys) { $0["passwordHistory"] = self.plain(history) }

        let sent = try await save(record)

        XCTAssertEqual(sent.passwordHistory, history, "JSONValue equality includes the order of the array")
        XCTAssertNotEqual(sent.passwordHistory, .array(history.arrayValue.reversed()))
    }

    // MARK: - Archived state (KEEP-03)

    func testArchivedFixtureItem_staysArchived() async throws {
        let golden = try await GoldenVault.load()
        let stored = golden.cipher(id: GoldenVault.archivedId)
        guard case .string? = stored.archivedDate else { return XCTFail("the fixture item is archived") }

        let sent = try await save(stored, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys)

        XCTAssertEqual(sent.archivedDate, stored.archivedDate)
    }

    func testArchivedDate_absentAndNull_stayAsTheyAre() async throws {
        for expected in [nil, JSONValue.null] as [JSONValue?] {
            let record = try storedRecord(for: sampleItem(1), keys: vaultKeys) {
                if let expected { $0["archivedDate"] = self.plain(expected) } else { $0.removeValue(forKey: "archivedDate") }
            }

            let sent = try await save(record)

            XCTAssertEqual(sent.archivedDate, expected)
            XCTAssertEqual(try encoded(sent)["archivedDate"], expected, "on the wire")
        }
    }

    // MARK: - SSH key fingerprint (KEEP-03)

    func testSSHFixtureItem_keyFingerprintSentUnchanged() async throws {
        let golden = try await GoldenVault.load()
        let stored = golden.cipher(id: GoldenVault.sshId)
        let storedFingerprint = try XCTUnwrap(stored.sshKey?.keyFingerprint)

        let sent = try await save(stored, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys)

        // The fingerprint is the stored EncString itself: a request without it makes Vaultwarden 1.37.4
        // drop the whole SSH key.
        XCTAssertEqual(sent.sshKey?.keyFingerprint, storedFingerprint)
        let itemKeys = try mapper.effectiveKeys(for: stored, activeKeys: golden.vaultKeys)
        XCTAssertTrue(try decrypt(stored.sshKey?.privateKey, keys: itemKeys).hasPrefix("-----BEGIN"))
        XCTAssertEqual(try decrypt(sent.sshKey?.privateKey, keys: itemKeys), try decrypt(stored.sshKey?.privateKey, keys: itemKeys))
    }

    func testSSHRecordWithoutFingerprint_sendsNone() async throws {
        let record = try storedRecord(for: sampleItem(5), keys: vaultKeys)
        XCTAssertNil(record.sshKey?.keyFingerprint)

        let sent = try await save(record)

        XCTAssertNil(sent.sshKey?.keyFingerprint)
        XCTAssertNil(try encoded(sent)["sshKey"].flatMap { value -> JSONValue? in
            guard case .object(let members) = value else { return nil }
            return members["keyFingerprint"]
        })
    }

    // MARK: - Unknown keys (KEEP-01, KEEP-03)

    func testAutofillOnPageLoad_keptIncludingNull() async throws {
        let variants: [(String, JSONValue?)] = [("true", .bool(true)), ("null", .null), ("absent", nil)]
        for (label, expected) in variants {
            let record = try storedRecord(for: sampleItem(1), keys: vaultKeys) { json in
                self.nested(&json, "login") { login in
                    if let expected { login["autofillOnPageLoad"] = self.plain(expected) }
                }
            }

            let sent = try await save(record)

            XCTAssertEqual(sent.login?.extras["autofillOnPageLoad"], expected, label)
        }
    }

    private let extraValue: JSONValue = .object(["nested": .array([.int(1), .null, .string("2.kept|x|y")])])

    func testNestedUnknownKeys_keptAtEveryLevel() async throws {
        // login, a website and a custom field
        let login = try storedRecord(for: sampleItem(1), keys: vaultKeys) { json in
            self.nested(&json, "login") { object in
                object["extraOnLogin"] = self.plain(self.extraValue)
                self.element(&object, "uris", 0) { $0["extraOnUri"] = self.plain(self.extraValue) }
            }
            var first = (json["fields"] as? [[String: Any]]) ?? []
            first[0]["extraOnField"] = self.plain(self.extraValue)
            json["fields"] = first
        }
        let sentLogin = try await save(login)
        XCTAssertEqual(sentLogin.login?.extras["extraOnLogin"], extraValue)
        XCTAssertEqual(sentLogin.login?.uris?.first?.extras["extraOnUri"], extraValue)
        XCTAssertNil(sentLogin.login?.uris?.last?.extras["extraOnUri"], "only the first website had it")
        XCTAssertEqual(sentLogin.fields?.first?.extras["extraOnField"], extraValue)

        // card, identity and SSH key
        for (type, section) in [(3, "card"), (4, "identity"), (5, "sshKey")] {
            let record = try storedRecord(for: sampleItem(type), keys: vaultKeys) { json in
                self.nested(&json, section) { $0["extraOn\(section)"] = self.plain(self.extraValue) }
            }
            let sent = try await save(record)
            let extras: [String: JSONValue]?
            switch type {
            case 3: extras = sent.card?.extras
            case 4: extras = sent.identity?.extras
            default: extras = sent.sshKey?.extras
            }
            XCTAssertEqual(extras?["extraOn\(section)"], extraValue, section)
        }
    }

    // MARK: - Websites: unknown keys follow their website

    private func recordWithTaggedURIs() throws -> RawCipher {
        try storedRecord(for: sampleItem(1), keys: vaultKeys) { json in
            self.nested(&json, "login") { login in
                self.element(&login, "uris", 0) { $0["tag"] = "on-a" }
                self.element(&login, "uris", 1) { $0["tag"] = "on-b" }
            }
        }
    }

    func testURIUnknownKeys_followTheirURIWhenReordered() async throws {
        let record = try recordWithTaggedURIs()

        let sent = try await save(record) { draft in
            guard case .login(var login) = draft.content else { return }
            login.uris.reverse()
            login.uris.append(DraftLoginURI(uri: "https://new.example.com"))
            draft.content = .login(login)
        }

        let uris = try XCTUnwrap(sent.login?.uris)
        XCTAssertEqual(try uris.map { try decrypt($0.uri, keys: vaultKeys) },
                       ["https://b.example.com", "https://a.example.com", "https://new.example.com"])
        XCTAssertEqual(uris.map { $0.extras["tag"] }, [.string("on-b"), .string("on-a"), nil])
    }

    func testURIUnknownKeys_droppedForARemovedURI() async throws {
        let record = try recordWithTaggedURIs()

        let sent = try await save(record) { draft in
            guard case .login(var login) = draft.content else { return }
            login.uris.removeFirst()  // website A goes
            draft.content = .login(login)
        }

        let uris = try XCTUnwrap(sent.login?.uris)
        XCTAssertEqual(uris.count, 1)
        XCTAssertEqual(try decrypt(uris[0].uri, keys: vaultKeys), "https://b.example.com")
        XCTAssertEqual(uris[0].extras["tag"], .string("on-b"))
        XCTAssertFalse(try encoded(sent).description.contains("on-a"), "nothing of the removed website is sent")
    }

    // MARK: - Custom fields: unknown keys follow the field with the same name and type

    private func recordWithTaggedFields() throws -> RawCipher {
        try storedRecord(for: sampleItem(1), keys: vaultKeys) { json in
            var fields = (json["fields"] as? [[String: Any]]) ?? []
            fields[0]["tag"] = "on-a"
            fields[1]["tag"] = "on-b"
            // A field without a name: kept and paired with the draft's nameless field
            // (fix-read-mapping-lossless-fields, design D4).
            fields.insert(["type": 0, "tag": "on-nameless"], at: 0)
            json["fields"] = fields
        }
    }

    private func tags(_ fields: [RawField]) -> [JSONValue?] { fields.map { $0.extras["tag"] } }

    /// The decrypted names, nil for a field sent without one.
    private func names(_ fields: [RawField]) throws -> [String?] {
        try fields.map { field in try field.name.map { try decrypt($0, keys: vaultKeys) } }
    }

    func testCustomFieldUnknownKeys_followTheirFieldWhenNothingChanged() async throws {
        let record = try recordWithTaggedFields()

        let sent = try await save(record)

        let fields = try XCTUnwrap(sent.fields)
        XCTAssertEqual(try names(fields), [nil, "Field A", "Field B"])
        XCTAssertEqual(tags(fields), [.string("on-nameless"), .string("on-a"), .string("on-b")])
    }

    func testCustomFieldUnknownKeys_followTheirFieldWhenReordered() async throws {
        let record = try recordWithTaggedFields()

        let sent = try await save(record) { draft in
            guard case .login(var login) = draft.content else { return }
            login.customFields.reverse()
            draft.content = .login(login)
        }

        let fields = try XCTUnwrap(sent.fields)
        XCTAssertEqual(try names(fields), ["Field B", "Field A", nil])
        XCTAssertEqual(tags(fields), [.string("on-b"), .string("on-a"), .string("on-nameless")])
    }

    func testCustomFieldUnknownKeys_droppedForARemovedField() async throws {
        let record = try recordWithTaggedFields()

        let sent = try await save(record) { draft in
            guard case .login(var login) = draft.content else { return }
            login.customFields.removeAll { $0.name == "Field A" }
            draft.content = .login(login)
        }

        let fields = try XCTUnwrap(sent.fields)
        XCTAssertEqual(try names(fields), [nil, "Field B"])
        XCTAssertEqual(tags(fields), [.string("on-nameless"), .string("on-b")])
        XCTAssertFalse(try encoded(sent).description.contains("on-a"), "nothing of the removed field is sent")
    }

    func testCustomFieldUnknownKeys_sameCountButOtherNameOrType_transferNothing() async throws {
        let record = try recordWithTaggedFields()

        let sent = try await save(record) { draft in
            guard case .login(var login) = draft.content else { return }
            // As if the stored record changed under an open sheet: the same number of fields, but
            // field A is called something else and field B has another type.
            login.customFields = [
                DraftCustomField(CustomField(name: "Renamed", value: "a", type: .text, linkedId: nil)),
                DraftCustomField(CustomField(name: "Field B", value: "b", type: .text, linkedId: nil)),
            ]
            draft.content = .login(login)
        }

        let fields = try XCTUnwrap(sent.fields)
        XCTAssertEqual(fields.count, 2)
        XCTAssertTrue(fields.allSatisfy { $0.extras.isEmpty }, "a field with another name or type takes no unknown key")
        XCTAssertFalse(try encoded(sent).description.contains("on-"), "no stored unknown key is sent on a guess")
    }

    func testCustomFieldUnknownKeys_sameNameInOrder_pairUpInStoredOrder() async throws {
        let twins = [
            CustomField(name: "Twin", value: "1", type: .text, linkedId: nil),
            CustomField(name: "Twin", value: "2", type: .text, linkedId: nil),
        ]
        let item = VaultItem(
            id: "item-1", name: "Twins", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate,
            content: .login(LoginContent(username: nil, password: nil, uris: [], totp: nil, notes: nil, customFields: twins)))
        let record = try storedRecord(for: item, keys: vaultKeys) { json in
            var fields = (json["fields"] as? [[String: Any]]) ?? []
            fields[0]["tag"] = "first"
            fields[1]["tag"] = "second"
            json["fields"] = fields
        }

        let unchanged = try await save(record)
        XCTAssertEqual(tags(try XCTUnwrap(unchanged.fields)), [.string("first"), .string("second")])

        // The first twin goes: the remaining one takes the first unused match, in stored order.
        let oneLeft = try await save(record) { draft in
            guard case .login(var login) = draft.content else { return }
            login.customFields.removeFirst()
            draft.content = .login(login)
        }
        XCTAssertEqual(tags(try XCTUnwrap(oneLeft.fields)), [.string("first")])
    }

    // MARK: - What the draft owns

    func testNeverCopiedFromTheStoredRecord_folderFavoriteOrganizationCollections() async throws {
        let orgKey = KeyedCipherBuilder.randomKeys()
        // A stored record that is stale after Prizm's own move, favorite and collection changes.
        let stored = try storedRecord(for: sampleItem(1), keys: orgKey) { json in
            json["folderId"] = "stale-folder"
            json["favorite"] = true
            json["organizationId"] = "org-1"
            json["collectionIds"] = ["stale-collection"]
        }

        let sent = try await save(stored, orgKeys: ["org-1": orgKey]) { draft in
            draft.folderId = "new-folder"
            draft.isFavorite = false
            draft.collectionIds = ["new-collection"]
            draft.name = "Edited"
        }

        XCTAssertEqual(sent.folderId, "new-folder")
        XCTAssertFalse(sent.favorite)
        XCTAssertEqual(sent.collectionIds, ["new-collection"])
        XCTAssertEqual(sent.organizationId, "org-1", "from the draft, which equals the record's")

        // And with nothing in the draft: a stale stored value is not a fallback.
        let sentCleared = try await save(stored, orgKeys: ["org-1": orgKey]) { draft in
            draft.folderId = nil
            draft.isFavorite = false
            draft.collectionIds = []
            draft.name = "Edited"
        }
        XCTAssertNil(sentCleared.folderId)
        XCTAssertFalse(sentCleared.favorite)
        XCTAssertEqual(sentCleared.collectionIds, [])
    }

    func testStoredRecordWithResponseOnlyKeys_requestHasNone() async throws {
        let record = try storedRecord(for: sampleItem(1), keys: vaultKeys) { json in
            json["data"] = #"{"legacy":"blob without a format version"}"#
            json["partialData"] = NSNull()
            json["edit"] = true
            json["viewPassword"] = true
            json["permissions"] = ["delete": true, "restore": true]
            json["object"] = "cipherDetails"
            json["organizationUseTotp"] = false
            self.nested(&json, "login") { $0["uri"] = "legacy-uri-echo" }
        }
        XCTAssertFalse(record.hasBlobData, "a data without a format version is not a blob")

        let sent = try await save(record)

        let members = try encoded(sent)
        for key in ["data", "partialData", "edit", "viewPassword", "permissions", "object", "organizationUseTotp"] {
            XCTAssertNil(members[key], "\(key) is response-only and must never be sent")
        }
        guard case .object(let login)? = members["login"] else { return XCTFail("no login") }
        XCTAssertNil(login["uri"], "the legacy first-URI echo would be appended to uris again by the official server")
        guard case .array(let uris)? = login["uris"] else { return XCTFail("no uris") }
        XCTAssertEqual(uris.count, 2)
    }

    func testFido2Response_sentAsReceived() async throws {
        let golden = try await GoldenVault.load()
        let stored = golden.cipher(id: GoldenVault.passkeyId)

        let sent = try await save(stored, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys)

        guard case .object(let login)? = try encoded(sent)["login"],
              case .array(let credentials)? = login["fido2Credentials"],
              case .object(let first)? = credentials.first else { return XCTFail("no passkey in the request") }
        XCTAssertEqual(first["response"], .null, "the member Vaultwarden sends as null is present and null")
        XCTAssertEqual(login["fido2Credentials"], stored.login?.extras["fido2Credentials"])
    }
}

private extension JSONValue {
    /// The elements of an array value; empty for any other case.
    var arrayValue: [JSONValue] {
        if case .array(let elements) = self { return elements }
        return []
    }
}
