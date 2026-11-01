import XCTest
@testable import Prizm

/// `login.passwordRevisionDate` is the date the official clients show for the last password change.
/// An edit sets it to the save time when the password was changed, added or cleared, and sends the
/// stored value unchanged otherwise (Bitwarden SDK `login.rs`, `detect_password_change`). The stored
/// and the new password are compared as plaintext inside the mapper, because the ciphertext differs
/// on every save even when the text does not. Real crypto throughout.
@MainActor
final class PasswordRevisionDateTests: XCTestCase {

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let saveTimeString = "2026-10-27T12:34:56.789Z"
    private let storedDate = "2025-01-02T03:04:05.678Z"
    private let vaultKeys = KeyedCipherBuilder.randomKeys()
    private lazy var saveTime: Date = Self.formatter.date(from: Self.saveTimeString)!
    private lazy var mapper = CipherMapper(now: { [saveTime] in saveTime })

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - Helpers

    private func loginItem(password: String?, id: String = "item-1") -> VaultItem {
        VaultItem(
            id: id, name: "Login", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate,
            content: .login(LoginContent(
                username: "user", password: password,
                uris: [LoginURI(uri: "https://a.example.com", matchType: nil)],
                totp: nil, notes: nil, customFields: [])))
    }

    /// The server's record: real EncStrings under `keys`, with `edit` applied to its JSON before it
    /// is decoded again, which is how a record that carries more than Prizm models reaches the app.
    private func storedRecord(
        _ item: VaultItem, keys: CryptoKeys? = nil, edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> RawCipher {
        let created = try CipherMapper().toUnkeyedRawCipher(DraftVaultItem(item), encryptedWith: keys ?? vaultKeys, encryptedFor: RepositoryFixtures.profileId)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(created)) as? [String: Any])
        // The create path writes no revision; a server record always has one, and a save needs it.
        json["revisionDate"] = RepositoryFixtures.serverRevisionString(for: item.revisionDate)
        edit(&json)
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A record of `password` that carries `date` as its `passwordRevisionDate` (nil leaves it absent).
    private func record(password: String?, date: Any?, id: String = "item-1") throws -> RawCipher {
        try storedRecord(loginItem(password: password, id: id)) { json in
            var login = json["login"] as? [String: Any] ?? [:]
            if let date { login["passwordRevisionDate"] = date }
            json["login"] = login
        }
    }

    private struct Rig {
        let api: MockPrizmAPIClient
        let repository: VaultRepositoryImpl
    }

    private func makeRig(storing record: RawCipher?) async -> Rig {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        let store = RawCipherStore()
        if let record {
            let token = await store.currentGeneration()
            await store.upsert(record, ifCurrent: token)
        }
        let repository = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, mapper: mapper, recordStore: store)
        return Rig(api: api, repository: repository)
    }

    /// Opens `record`'s draft as the edit sheet would, sets `password` and saves. The username is
    /// renamed too, so an unchanged password still takes the full-save path. Returns the request.
    @discardableResult
    private func save(
        _ record: RawCipher, password: String?, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> RawCipher {
        let rig = await makeRig(storing: record)
        var draft = DraftVaultItem(try mapper.map(raw: record, vaultKeys: vaultKeys).item)
        draft.name = "Edited"
        guard case .login(var login) = draft.content else { throw CocoaError(.coderInvalidValue) }
        login.password = password
        draft.content = .login(login)
        _ = try await rig.repository.update(draft)
        return try XCTUnwrap(rig.api.lastUpdatedCipher, "no request was sent", file: file, line: line)
    }

    private func encodedLogin(_ cipher: RawCipher) throws -> [String: JSONValue] {
        guard case .object(let members) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cipher)),
              case .object(let login)? = members["login"] else {
            throw CocoaError(.coderInvalidValue)
        }
        return login
    }

    // MARK: - Tracer: the real client sends the save time when the password changes

    func testChangedPassword_putBodyCarriesTheSaveTime() async throws {
        let stored = try record(password: "old-password", date: storedDate)
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        await client.setAccessToken("token")
        let crypto = PrizmCryptoServiceImpl()
        await crypto.unlockWith(keys: vaultKeys)
        let store = RawCipherStore()
        let token = await store.currentGeneration()
        await store.upsert(stored, ifCurrent: token)
        let repository = await RepositoryFixtures.vaultRepository(
            apiClient: client, crypto: crypto, mapper: mapper, recordStore: store)
        StubURLProtocol.responder = { _ in .status(200, body: StubURLProtocol.requests.last?.body ?? Data()) }

        var draft = DraftVaultItem(try mapper.map(raw: stored, vaultKeys: vaultKeys).item)
        guard case .login(var login) = draft.content else { return XCTFail("not a login") }
        login.password = "new-password"
        draft.content = .login(login)
        _ = try await repository.update(draft)

        let put = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(put.method, "PUT")
        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(put.body))
        guard case .object(let members) = body, case .object(let sentLogin)? = members["login"] else {
            return XCTFail("unexpected body shape")
        }
        XCTAssertEqual(sentLogin["passwordRevisionDate"], .string(Self.saveTimeString))
    }

    // MARK: - Kept when the password is not changed

    func testUnchangedPassword_keepsTheStoredDate() async throws {
        let sent = try await save(try record(password: "same", date: storedDate), password: "same")
        XCTAssertEqual(sent.login?.passwordRevisionDate, storedDate)
    }

    func testSamePasswordSavedAgain_keepsTheStoredDate() async throws {
        let stored = try record(password: "same", date: storedDate)
        let sent = try await save(stored, password: "same")

        XCTAssertNotEqual(sent.login?.password, stored.login?.password, "the ciphertext changes on every save")
        XCTAssertEqual(sent.login?.passwordRevisionDate, storedDate)
    }

    func testWhitespaceOrCaseChange_countsAsAChange() async throws {
        for changed in ["same ", " same", "Same", "SAME"] {
            let sent = try await save(try record(password: "same", date: storedDate), password: changed)
            XCTAssertEqual(sent.login?.passwordRevisionDate, Self.saveTimeString, "'\(changed)'")
        }
    }

    // MARK: - Set when the password is changed, added or cleared

    func testAddedPassword_setsTheSaveTime() async throws {
        for stored in [nil, ""] as [String?] {
            let sent = try await save(try record(password: stored, date: storedDate), password: "new")
            XCTAssertEqual(sent.login?.passwordRevisionDate, Self.saveTimeString, "stored \(String(describing: stored))")
        }
    }

    func testClearedPassword_setsTheSaveTime() async throws {
        for new in [nil, ""] as [String?] {
            let sent = try await save(try record(password: "old", date: storedDate), password: new)
            XCTAssertEqual(sent.login?.passwordRevisionDate, Self.saveTimeString, "new \(String(describing: new))")
        }
    }

    func testChangedPasswordOnARecordWithoutADate_setsTheSaveTime() async throws {
        let sent = try await save(try record(password: "old", date: nil), password: "new")
        XCTAssertEqual(sent.login?.passwordRevisionDate, Self.saveTimeString)
    }

    // MARK: - nil and empty are alike

    func testBothEmpty_keepTheStoredDate() async throws {
        for (stored, new) in [(nil, ""), ("", nil), (nil, nil), ("", "")] as [(String?, String?)] {
            let sent = try await save(try record(password: stored, date: storedDate), password: new)
            XCTAssertEqual(sent.login?.passwordRevisionDate, storedDate,
                           "stored \(String(describing: stored)), new \(String(describing: new))")
        }
    }

    func testBothEmpty_withoutAStoredDate_staysAbsent() async throws {
        for (stored, new) in [(nil, ""), ("", nil)] as [(String?, String?)] {
            let sent = try await save(try record(password: stored, date: nil), password: new)
            XCTAssertNil(sent.login?.passwordRevisionDate)
            XCTAssertNil(try encodedLogin(sent)["passwordRevisionDate"], "no key on the wire")
        }
    }

    // MARK: - Ordering: the rule never compares dates

    func testWrongTypedStoredDate_keptWhenUnchangedAndReplacedOnceWhenChanged() async throws {
        let unchanged = try await save(try record(password: "same", date: 12345), password: "same")
        XCTAssertNil(unchanged.login?.passwordRevisionDate, "the wrong-typed value is not a string")
        XCTAssertEqual(try encodedLogin(unchanged)["passwordRevisionDate"], .int(12345), "kept verbatim")

        let changed = try await save(try record(password: "same", date: 12345), password: "different")
        XCTAssertEqual(changed.login?.passwordRevisionDate, Self.saveTimeString)
        let wire = try JSONEncoder().encode(changed)
        let text = try XCTUnwrap(String(data: wire, encoding: .utf8))
        XCTAssertEqual(text.components(separatedBy: "\"passwordRevisionDate\"").count - 1, 1, "the key is sent exactly once")
        XCTAssertEqual(try encodedLogin(changed)["passwordRevisionDate"], .string(Self.saveTimeString))
    }

    // MARK: - Fail closed

    func testStoredPasswordUnderAnotherKey_failsWithItemKeyUnavailable() async throws {
        // The name is under the vault key (it passes the key check); the password is not.
        let foreign = KeyedCipherBuilder.encrypt("old", keys: KeyedCipherBuilder.randomKeys())
        let mixed = try storedRecord(loginItem(password: "old")) { json in
            var login = json["login"] as? [String: Any] ?? [:]
            login["password"] = foreign
            login["passwordRevisionDate"] = self.storedDate
            json["login"] = login
        }

        let rig = await makeRig(storing: mixed)
        var draft = DraftVaultItem(try mapper.map(raw: try record(password: "old", date: storedDate), vaultKeys: vaultKeys).item)
        guard case .login(var login) = draft.content else { return XCTFail("not a login") }
        login.password = "new"
        draft.content = .login(login)

        do {
            _ = try await rig.repository.update(draft)
            XCTFail("Expected itemKeyUnavailable")
        } catch VaultError.itemKeyUnavailable {
            // expected
        } catch {
            XCTFail("Expected itemKeyUnavailable, got \(error)")
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 0, "nothing is sent")
        XCTAssertEqual(rig.api.updateCipherCollectionsCallCount, 0)
    }

    // MARK: - Create and other item types

    func testCreate_neverSendsPasswordRevisionDate() async throws {
        let rig = await makeRig(storing: nil)
        var draft = DraftVaultItem(loginItem(password: "brand-new", id: "new"))
        draft.name = "Created"

        _ = try await rig.repository.create(draft)

        let sent = try XCTUnwrap(rig.api.lastCreatedCipher)
        XCTAssertNil(sent.login?.passwordRevisionDate)
        XCTAssertNil(try encodedLogin(sent)["passwordRevisionDate"])
    }

    func testNonLoginItems_unaffected() async throws {
        let note = VaultItem(
            id: "note", name: "Note", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate,
            content: .secureNote(SecureNoteContent(notes: "n", customFields: [])))
        let card = VaultItem(
            id: "card", name: "Card", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate,
            content: .card(CardContent(
                cardholderName: "H", brand: nil, number: "4111111111111111", expMonth: nil, expYear: nil,
                code: nil, notes: nil, customFields: [])))
        for item in [note, card] {
            let stored = try storedRecord(item)
            let rig = await makeRig(storing: stored)
            var draft = DraftVaultItem(item)
            draft.name = "Edited"
            _ = try await rig.repository.update(draft)

            let sent = try XCTUnwrap(rig.api.lastUpdatedCipher)
            XCTAssertNil(sent.login, "item \(item.id)")
            let text = String(data: try JSONEncoder().encode(sent), encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("passwordRevisionDate"), "item \(item.id)")
        }
    }

    // MARK: - Password history gets the old password in front (password-history)

    func testPasswordChange_prependsToHistory() async throws {
        let history: JSONValue = .array([
            .object(["password": .string("2.AAAA|BBBB|CCCC"), "lastUsedDate": .string("2026-01-01T00:00:00.000Z")]),
        ])
        let stored = try storedRecord(loginItem(password: "old")) { json in
            json["passwordHistory"] = [["password": "2.AAAA|BBBB|CCCC", "lastUsedDate": "2026-01-01T00:00:00.000Z"]]
        }
        XCTAssertEqual(stored.passwordHistory, history)

        let sent = try await save(stored, password: "new")

        XCTAssertEqual(sent.login?.passwordRevisionDate, Self.saveTimeString)
        guard case .array(let sentHistory)? = sent.passwordHistory, case .array(let storedHistory) = history else {
            return XCTFail("history is not a list")
        }
        XCTAssertEqual(sentHistory.count, 2)
        XCTAssertEqual(Array(sentHistory.dropFirst()), storedHistory, "the stored entry goes back as it was")
    }

    // MARK: - Format

    func testFormat_isISO8601UTCWithMillisecondsAndZ() async throws {
        // The injected clock is fixed, so this is the exact string; the regex pins the shape.
        let sent = try await save(try record(password: "a", date: storedDate), password: "b")
        let date = try XCTUnwrap(sent.login?.passwordRevisionDate)
        XCTAssertNotNil(date.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression), date)
        XCTAssertEqual(date, Self.saveTimeString)

        // The default clock is the current time.
        let before = Date()
        let live = try CipherMapper().toRawCipher(
            DraftVaultItem(loginItem(password: "b")), overlaying: try record(password: "a", date: storedDate),
            effectiveKeys: vaultKeys, encryptedFor: "pid")
        let liveDate = try XCTUnwrap(live.login?.passwordRevisionDate.flatMap { Self.formatter.date(from: $0) })
        XCTAssertLessThan(abs(liveDate.timeIntervalSince(before)), 5)
    }
}
