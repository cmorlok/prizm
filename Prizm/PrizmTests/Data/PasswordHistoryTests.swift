import XCTest
@testable import Prizm

/// Password history (openspec change `password-history`): the count and the password revision date
/// at sync (task 2.2), the entries decrypted on demand (2.3), and the entries a save adds (3.2).
/// Real crypto throughout.
@MainActor
final class PasswordHistoryTests: XCTestCase {

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let saveTimeString = "2026-10-27T12:34:56.789Z"
    private let vaultKeys = KeyedCipherBuilder.randomKeys()
    private lazy var saveTime: Date = Self.formatter.date(from: Self.saveTimeString)!
    private lazy var mapper = CipherMapper(now: { [saveTime] in saveTime })

    // MARK: - Helpers

    private func item(_ content: ItemContent, id: String = "item-1") -> VaultItem {
        VaultItem(id: id, name: "Item", isFavorite: false, isDeleted: false,
                  creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate, content: content)
    }

    private func login(password: String?, fields: [CustomField] = []) -> ItemContent {
        .login(LoginContent(username: "user", password: password, uris: [], totp: nil, notes: nil,
                            customFields: fields))
    }

    private func entry(_ plaintext: String, _ date: String, keys: CryptoKeys? = nil) -> [String: Any] {
        ["password": KeyedCipherBuilder.encrypt(plaintext, keys: keys ?? vaultKeys), "lastUsedDate": date]
    }

    /// The server's record of `item` under `keys`, with `history` as its `passwordHistory` (a Swift
    /// value for `JSONSerialization`; `NSNull()` for null; nil leaves the key absent).
    private func record(_ item: VaultItem, history: Any?, keys: CryptoKeys? = nil,
                        edit: (inout [String: Any]) -> Void = { _ in }) throws -> RawCipher {
        let created = try CipherMapper().toUnkeyedRawCipher(DraftVaultItem(item), encryptedWith: keys ?? vaultKeys,
                                                        encryptedFor: RepositoryFixtures.profileId)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(created)) as? [String: Any])
        json["revisionDate"] = RepositoryFixtures.serverRevisionString(for: item.revisionDate)
        if let history { json["passwordHistory"] = history }
        edit(&json)
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private struct Rig {
        let api: MockPrizmAPIClient
        let crypto: MockPrizmCryptoService
        let store: RawCipherStore
        let repository: VaultRepositoryImpl
    }

    private func makeRig(storing record: RawCipher?, unlocked: Bool = true,
                         orgKeys: [String: CryptoKeys] = [:]) async -> Rig {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        if unlocked {
            await crypto.unlockWith(keys: vaultKeys)
            crypto.stubbedVaultKeys = vaultKeys
        }
        let store = RawCipherStore()
        if let record {
            let token = await store.currentGeneration()
            await store.upsert(record, ifCurrent: token)
        }
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: orgKeys)
        let repository = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, mapper: mapper, orgKeyCache: orgKeyCache, recordStore: store)
        return Rig(api: api, crypto: crypto, store: store, repository: repository)
    }

    /// Saves `record` with `change` applied to its draft (the name is changed too, so the full-save
    /// path runs) and returns the request.
    private func save(_ record: RawCipher, rig: Rig? = nil,
                      change: (inout DraftVaultItem) -> Void) async throws -> RawCipher {
        let rig = await { if let rig { return rig }; return await makeRig(storing: record) }()
        var draft = DraftVaultItem(try mapper.map(raw: record, vaultKeys: vaultKeys).item)
        draft.name = "Edited"
        change(&draft)
        _ = try await rig.repository.update(draft)
        return try XCTUnwrap(rig.api.lastUpdatedCipher, "no request was sent")
    }

    private func setPassword(_ password: String?) -> (inout DraftVaultItem) -> Void {
        { draft in
            guard case .login(var login) = draft.content else { return XCTFail("not a login") }
            login.password = password
            draft.content = .login(login)
        }
    }

    private func elements(_ cipher: RawCipher) throws -> [JSONValue] {
        guard case .array(let elements)? = cipher.passwordHistory else {
            throw CocoaError(.coderInvalidValue)
        }
        return elements
    }

    /// The plaintext and date of an element the save added.
    private func decrypt(_ element: JSONValue, keys: CryptoKeys? = nil) throws -> (String, String?) {
        guard case .object(let o) = element, case .string(let enc)? = o["password"] else {
            throw CocoaError(.coderInvalidValue)
        }
        let data = try EncString(string: enc).decrypt(keys: keys ?? vaultKeys)
        var date: String?
        if case .string(let s)? = o["lastUsedDate"] { date = s }
        return (String(decoding: data, as: UTF8.self), date)
    }

    private func wrapped(_ itemKey: CryptoKeys) -> String {
        try! EncString.encrypt(data: itemKey.toData(), keys: vaultKeys).toString()
    }

    // MARK: - 2.2 Count and revision date at sync, never values

    func testMap_countIsTheNumberOfArrayElements() throws {
        let cases: [(Any?, Int)] = [
            (nil, 0), (NSNull(), 0), ([Any](), 0),
            ([entry("a", "2026-01-01T00:00:00.000Z"), 42], 2),
            ("not a list", 0),
        ]
        for (history, expected) in cases {
            let raw = try record(item(login(password: "p")), history: history)
            let mapped = try mapper.map(raw: raw, vaultKeys: vaultKeys).item
            XCTAssertEqual(mapped.passwordHistoryCount, expected, "\(String(describing: history))")
        }
    }

    func testMap_readsPasswordRevisionDate() throws {
        let raw = try record(item(login(password: "p")), history: nil) { json in
            var login = json["login"] as? [String: Any] ?? [:]
            login["passwordRevisionDate"] = "2025-01-02T03:04:05.678Z"
            json["login"] = login
        }
        guard case .login(let content) = try mapper.map(raw: raw, vaultKeys: vaultKeys).item.content else {
            return XCTFail("not a login")
        }
        XCTAssertEqual(content.passwordRevisionDate, Self.formatter.date(from: "2025-01-02T03:04:05.678Z"))

        let without = try record(item(login(password: "p")), history: nil)
        guard case .login(let none) = try mapper.map(raw: without, vaultKeys: vaultKeys).item.content else {
            return XCTFail("not a login")
        }
        XCTAssertNil(none.passwordRevisionDate)
    }

    // MARK: - 2.3 Decrypted on demand

    func testHistory_decryptsEntriesInStoredOrder() async throws {
        let raw = try record(item(login(password: "p")), history: [
            entry("newer", "2026-02-01T00:00:00.000Z"), entry("older", "2026-01-01T00:00:00Z"),
        ])
        let rig = await makeRig(storing: raw)

        let entries = try await rig.repository.passwordHistory(itemId: "item-1")

        XCTAssertEqual(entries.map(\.value), ["newer", "older"])
        XCTAssertEqual(entries.map(\.lastUsedDate), [
            Self.formatter.date(from: "2026-02-01T00:00:00.000Z"),
            ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"),
        ])
    }

    func testHistory_unreadableEntriesAndDates_areMarkedAndTheOthersStillShow() async throws {
        let foreign = KeyedCipherBuilder.randomKeys()
        let raw = try record(item(login(password: "p")), history: [
            entry("good", "2026-02-01T00:00:00.000Z"),
            42,
            ["lastUsedDate": "2026-01-01T00:00:00.000Z"],
            entry("other key", "2026-01-01T00:00:00.000Z", keys: foreign),
            entry("no date", "yesterday"),
        ])
        let rig = await makeRig(storing: raw)

        let entries = try await rig.repository.passwordHistory(itemId: "item-1")

        XCTAssertEqual(entries.map(\.value), ["good", nil, nil, nil, "no date"])
        XCTAssertNotNil(entries[2].lastUsedDate, "the date of an entry without a password is still read")
        XCTAssertNil(entries[4].lastUsedDate, "Unknown date")
    }

    func testHistory_ofAPerItemKeyItem_usesTheItemKey() async throws {
        // An item with its own key: every field and every history entry is under that key.
        let itemKey = KeyedCipherBuilder.randomKeys()
        let raw = try record(item(login(password: "p")), history: [entry("keyed", "2026-01-01T00:00:00.000Z", keys: itemKey)],
                             keys: itemKey) { json in
            json["key"] = self.wrapped(itemKey)
        }
        let rig = await makeRig(storing: raw)

        let entries = try await rig.repository.passwordHistory(itemId: "item-1")

        XCTAssertEqual(entries.map(\.value), ["keyed"])
    }

    func testHistory_nonArrayOrAbsent_isEmpty() async throws {
        for history in [nil, NSNull(), "not a list"] as [Any?] {
            let rig = await makeRig(storing: try record(item(login(password: "p")), history: history))
            let entries = try await rig.repository.passwordHistory(itemId: "item-1")
            XCTAssertEqual(entries, [], "\(String(describing: history))")
        }
    }

    func testHistory_lockedVault_throwsVaultLocked() async throws {
        let rig = await makeRig(storing: try record(item(login(password: "p")), history: [entry("x", "2026-01-01T00:00:00.000Z")]),
                                unlocked: false)
        do {
            _ = try await rig.repository.passwordHistory(itemId: "item-1")
            XCTFail("Expected vaultLocked")
        } catch VaultError.vaultLocked {
            // expected
        }
    }

    func testHistory_lockDuringTheLoad_isDropped() async throws {
        let rig = await makeRig(storing: try record(item(login(password: "p")), history: [entry("x", "2026-01-01T00:00:00.000Z")]))
        // The vault is cleared while the keys are read: the result must not come back.
        // `clearVault()` invalidates the store first, synchronously; this is that step.
        rig.crypto.whileReadingKeys = { [store = rig.store] in store.invalidate() }
        do {
            _ = try await rig.repository.passwordHistory(itemId: "item-1")
            XCTFail("Expected vaultLocked")
        } catch VaultError.vaultLocked {
            // expected
        }
    }

    func testHistory_withoutAStoredRecord_throwsItemRecordUnavailable() async throws {
        let rig = await makeRig(storing: nil)
        do {
            _ = try await rig.repository.passwordHistory(itemId: "item-1")
            XCTFail("Expected itemRecordUnavailable")
        } catch VaultError.itemRecordUnavailable {
            // expected
        }
    }

    // MARK: - 3.2 Entries added on save

    func testSave_changedPassword_prependsTheOldPasswordAndKeepsTheRestByteForByte() async throws {
        let raw = try record(item(login(password: "old")), history: [entry("oldest", "2026-01-01T00:00:00.000Z"), 42])
        let stored = try elements(raw)

        let sent = try await save(raw, change: setPassword("new"))

        let history = try elements(sent)
        XCTAssertEqual(history.count, 3)
        let (value, date) = try decrypt(history[0])
        XCTAssertEqual(value, "old")
        XCTAssertEqual(date, Self.saveTimeString)
        XCTAssertEqual(sent.login?.passwordRevisionDate, Self.saveTimeString, "one save time for both")
        XCTAssertEqual(Array(history[1...]), stored, "the stored elements, non-object ones too, unchanged")
    }

    func testSave_clearedPassword_isRecorded() async throws {
        let sent = try await save(try record(item(login(password: "old")), history: nil), change: setPassword(nil))
        XCTAssertEqual(try decrypt(try elements(sent)[0]).0, "old")
    }

    func testSave_keepsFive() async throws {
        let five = (1...5).map { entry("p\($0)", "2026-01-0\($0)T00:00:00.000Z") }
        let raw = try record(item(login(password: "old")), history: five)
        let stored = try elements(raw)

        let sent = try await save(raw, change: setPassword("new"))

        let history = try elements(sent)
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(try decrypt(history[0]).0, "old")
        XCTAssertEqual(Array(history[1...]), Array(stored.prefix(4)), "the oldest entry is dropped")
    }

    func testSave_absentOrNullHistory_startsAList() async throws {
        for history in [nil, NSNull()] as [Any?] {
            let sent = try await save(try record(item(login(password: "old")), history: history), change: setPassword("new"))
            XCTAssertEqual(try elements(sent).count, 1, "\(String(describing: history))")
        }
    }

    func testSave_nothingRecorded_sendsTheHistoryAsReceived() async throws {
        // Absent stays absent, null stays null.
        let absent = try await save(try record(item(login(password: "same")), history: nil), change: setPassword("same"))
        XCTAssertNil(absent.passwordHistory)
        let null = try await save(try record(item(login(password: "same")), history: NSNull()), change: setPassword("same"))
        XCTAssertEqual(null.passwordHistory, .null)
    }

    func testSave_nonArrayHistory_isSentUnchangedWithoutAnEntry() async throws {
        let sent = try await save(try record(item(login(password: "old")), history: "not a list"), change: setPassword("new"))
        XCTAssertEqual(sent.passwordHistory, .string("not a list"))
        XCTAssertEqual(sent.login?.passwordRevisionDate, Self.saveTimeString, "the date is still set")
    }

    func testSave_firstPassword_onlySetsTheDate() async throws {
        let sent = try await save(try record(item(login(password: nil)), history: nil), change: setPassword("first"))
        XCTAssertNil(sent.passwordHistory)
        XCTAssertEqual(sent.login?.passwordRevisionDate, Self.saveTimeString)
    }

    func testSave_hiddenFieldOnASecureNote_isRecorded() async throws {
        let note = item(.secureNote(SecureNoteContent(notes: nil, customFields: [
            CustomField(name: "PIN", value: "1234", type: .hidden, linkedId: nil),
            CustomField(name: "Label", value: "text", type: .text, linkedId: nil),
        ])))
        let sent = try await save(try record(note, history: nil)) { draft in
            guard case .secureNote(var c) = draft.content else { return XCTFail("not a note") }
            c.customFields[0].value = "9999"
            c.customFields[1].value = "changed"
            draft.content = .secureNote(c)
        }
        let history = try elements(sent)
        XCTAssertEqual(history.count, 1, "the text field is not recorded")
        XCTAssertEqual(try decrypt(history[0]).0, "PIN: 1234")
    }

    func testHistory_ofAnOrgItem_usesTheOrgKey_andNeedsIt() async throws {
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let raw = try record(item(login(password: "p")), history: [entry("shared", "2026-01-01T00:00:00.000Z", keys: orgKeys)],
                             keys: orgKeys) { json in
            json["organizationId"] = "org-1"
        }
        let withKey = await makeRig(storing: raw, orgKeys: ["org-1": orgKeys])
        let entries = try await withKey.repository.passwordHistory(itemId: "item-1")
        XCTAssertEqual(entries.map(\.value), ["shared"])

        let withoutKey = await makeRig(storing: raw)
        do {
            _ = try await withoutKey.repository.passwordHistory(itemId: "item-1")
            XCTFail("an org item's history needs the org key; no fallback")
        } catch VaultError.organizationKeyUnavailable {}
    }

    func testSave_hiddenFieldRemovedFromACard_isRecorded_otherTypesAreNot() async throws {
        let card = item(.card(CardContent(cardholderName: "A", brand: nil, number: nil, expMonth: nil,
                                          expYear: nil, code: nil, notes: nil, customFields: [
            CustomField(name: "PIN", value: "1234", type: .hidden, linkedId: nil),
            CustomField(name: "Flag", value: "true", type: .boolean, linkedId: nil),
            CustomField(name: "Mirror", value: nil, type: .linked, linkedId: .cardNumber),
        ])))
        let sent = try await save(try record(card, history: nil)) { draft in
            guard case .card(var c) = draft.content else { return XCTFail("not a card") }
            c.customFields = []
            draft.content = .card(c)
        }
        let history = try elements(sent)
        XCTAssertEqual(history.count, 1, "only the hidden field is recorded")
        XCTAssertEqual(try decrypt(history[0]).0, "PIN: 1234")
    }

    func testSave_answerGivesTheNewCount() async throws {
        let raw = try record(item(login(password: "old")), history: nil)
        let rig = await makeRig(storing: raw)
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        var draft = DraftVaultItem(try mapper.map(raw: raw, vaultKeys: vaultKeys).item)
        setPassword("new")(&draft)

        let saved = try await rig.repository.update(draft)

        XCTAssertEqual(saved.passwordHistoryCount, 1, "the footer shows the entry the save added")
    }

    func testSave_perItemKeyItem_encryptsEntriesWithTheItemKey() async throws {
        let itemKey = KeyedCipherBuilder.randomKeys()
        let raw = try record(item(login(password: "old")), history: nil, keys: itemKey) { json in
            json["key"] = self.wrapped(itemKey)
        }
        let sent = try await save(raw, change: setPassword("new"))
        XCTAssertEqual(try decrypt(try elements(sent)[0], keys: itemKey).0, "old")
    }

    func testSave_secondSaveWithTheSamePassword_addsNoSecondEntry() async throws {
        // The comparison is against the server's stored record, so saving again (a retry after a
        // collection change that failed, say) does not record the same password twice.
        let raw = try record(item(login(password: "old")), history: nil)
        let rig = await makeRig(storing: raw)
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        _ = try await save(raw, rig: rig, change: setPassword("new"))

        let stored = try XCTUnwrap(rig.api.updateCipherResponse)
        let again = try await save(stored, rig: rig) { $0.name = "Edited again" }

        XCTAssertEqual(try elements(again).count, 1)
    }

    func testSave_folderOnlyChange_goesThroughPartialAndLeavesTheHistory() async throws {
        let raw = try record(item(login(password: "old")), history: [entry("x", "2026-01-01T00:00:00.000Z")])
        let rig = await makeRig(storing: raw)
        let cached = try mapper.map(raw: raw, vaultKeys: vaultKeys).item
        await rig.repository.populate(items: [cached], folders: [], organizations: [], collections: [], syncedAt: Date())

        var draft = DraftVaultItem(cached)
        draft.isFavorite = true
        _ = try await rig.repository.update(draft)

        XCTAssertEqual(rig.api.updateCipherCallCount, 0, "no full save, so nothing is added")
    }
}
