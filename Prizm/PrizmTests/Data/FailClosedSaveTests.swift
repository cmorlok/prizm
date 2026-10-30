import XCTest
@testable import Prizm

/// A save fails before anything is encrypted or sent when Prizm cannot be sure which key the server
/// expects: no stored record, a draft that belongs to another organization than the record, an item
/// key that does not unwrap, or a stored name that does not verify under the key. Nothing falls back
/// to another key, and the edit sheet keeps the user's input with a lock-and-unlock message.
@MainActor
final class FailClosedSaveTests: XCTestCase {

    private var api: MockPrizmAPIClient!
    private var crypto: MockPrizmCryptoService!
    private var store: RawCipherStore!
    private var orgKeyCache: OrgKeyCache!
    private var sut: VaultRepositoryImpl!

    private let mapper = CipherMapper()
    private let vaultKeys = KeyedCipherBuilder.randomKeys()
    private let orgAKeys = KeyedCipherBuilder.randomKeys()
    private let orgBKeys = KeyedCipherBuilder.randomKeys()

    override func setUp() async throws {
        try await super.setUp()
        api = MockPrizmAPIClient()
        crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        store = RawCipherStore()
        orgKeyCache = OrgKeyCache()
        sut = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, recordStore: store)
    }

    // MARK: - Helpers

    private func seed(_ record: RawCipher) async {
        let token = await store.currentGeneration()
        await store.upsert(record, ifCurrent: token)
    }

    /// A draft that differs from `record`'s item by its name, so it takes the full-save path.
    private func draft(of record: RawCipher, orgKeys: [String: CryptoKeys] = [:], name: String = "Edited") throws -> DraftVaultItem {
        var draft = DraftVaultItem(try mapper.map(raw: record, vaultKeys: vaultKeys, orgKeys: orgKeys).item)
        draft.name = name
        return draft
    }

    private func assertNothingSent(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(api.updateCipherCallCount, 0, "no PUT may be sent", file: file, line: line)
        XCTAssertEqual(api.updateCipherCollectionsCallCount, 0, "no collections request may be sent", file: file, line: line)
    }

    private func assertSaveFails(
        _ draft: DraftVaultItem, expecting matches: (VaultError) -> Bool, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await sut.update(draft)
            XCTFail("Expected \(label)", file: file, line: line)
        } catch let error as VaultError {
            XCTAssertTrue(matches(error), "Expected \(label), got \(error)", file: file, line: line)
        } catch {
            XCTFail("Expected \(label), got \(error)", file: file, line: line)
        }
        assertNothingSent(file: file, line: line)
    }

    private func isRecordUnavailable(_ error: VaultError) -> Bool {
        if case .itemRecordUnavailable = error { return true }
        return false
    }

    private func isKeyUnavailable(_ error: VaultError) -> Bool {
        if case .itemKeyUnavailable = error { return true }
        return false
    }

    /// `record` with another `key`, as a server could hold it.
    private func replacingKey(of record: RawCipher, with key: String) throws -> RawCipher {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["key"] = key
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The type-0 form of a type-2 EncString: same IV and ciphertext, no MAC part.
    private func withoutMAC(_ type2: String) -> String {
        let body = type2.dropFirst(2)  // "2."
        let parts = body.split(separator: "|")
        return "0.\(parts[0])|\(parts[1])"
    }

    // MARK: - No record, organization mismatch

    func testNoStoredRecord_throwsItemRecordUnavailable() async throws {
        let record = KeyedCipherBuilder.login(id: "gone", name: "Gone", activeKeys: vaultKeys)
        // Not stored.
        await assertSaveFails(try draft(of: record), expecting: isRecordUnavailable, "itemRecordUnavailable")
    }

    func testDraftPersonalButStoredRecordOrg_fails() async throws {
        await orgKeyCache.replaceAll(with: ["org-a": orgAKeys])
        let record = KeyedCipherBuilder.login(
            id: "shared", name: "Shared", organizationId: "org-a", collectionIds: ["col-1"], activeKeys: orgAKeys)
        await seed(record)
        var edited = try draft(of: record, orgKeys: ["org-a": orgAKeys])
        edited.organizationId = nil
        edited.collectionIds = []

        await assertSaveFails(edited, expecting: isRecordUnavailable, "itemRecordUnavailable")
    }

    func testDraftOrgADifferentFromStoredOrgB_fails() async throws {
        await orgKeyCache.replaceAll(with: ["org-a": orgAKeys, "org-b": orgBKeys])
        let record = KeyedCipherBuilder.login(
            id: "shared", name: "Shared", organizationId: "org-b", collectionIds: ["col-1"], activeKeys: orgBKeys)
        await seed(record)
        var edited = try draft(of: record, orgKeys: ["org-b": orgBKeys])
        edited.organizationId = "org-a"

        await assertSaveFails(edited, expecting: isRecordUnavailable, "itemRecordUnavailable")
    }

    func testOrgRecordWithoutOrgKey_failsWithOrganizationKeyUnavailable() async throws {
        let record = KeyedCipherBuilder.login(
            id: "shared", name: "Shared", organizationId: "org-a", collectionIds: ["col-1"], activeKeys: orgAKeys)
        await seed(record)  // the cache has no org key: never the vault key
        let edited = try draft(of: record, orgKeys: ["org-a": orgAKeys])

        await assertSaveFails(edited, expecting: { error in
            if case .organizationKeyUnavailable = error { return true }
            return false
        }, "organizationKeyUnavailable")
    }

    // MARK: - Item key and key check

    func testItemKeyDoesNotUnwrap_throwsItemKeyUnavailable() async throws {
        let itemKey = KeyedCipherBuilder.randomKeys()
        let readable = KeyedCipherBuilder.login(id: "k", name: "Keyed", activeKeys: vaultKeys, itemKey: itemKey)
        let broken = KeyedCipherBuilder.login(
            id: "k", name: "Keyed", activeKeys: vaultKeys, itemKey: itemKey,
            wrappingKeys: KeyedCipherBuilder.randomKeys())
        await seed(broken)

        await assertSaveFails(try draft(of: readable), expecting: isKeyUnavailable, "itemKeyUnavailable")
    }

    func testStoredNameUnderAnotherKey_failsTheKeyCheck() async throws {
        // Keyless record whose name was encrypted with another key: nothing unwraps, so only the key
        // check can notice that the vault key is not the key the record's fields use.
        let readable = KeyedCipherBuilder.login(id: "m", name: "Mixed", activeKeys: vaultKeys)
        let mixed = KeyedCipherBuilder.login(
            id: "m", name: "Mixed", activeKeys: vaultKeys, fieldKeys: KeyedCipherBuilder.randomKeys())
        await seed(mixed)

        await assertSaveFails(try draft(of: readable), expecting: isKeyUnavailable, "itemKeyUnavailable")
    }

    /// A type-0 name is refused twice: as not editable before any key work (the stored record's edit
    /// block, `testFullSaveOfAStoredTypeZeroName_isRefusedAsNotEditable` in `EditGuardTests`), and by
    /// the key check itself, which this test calls directly because the first refusal now comes
    /// before it on every save.
    func testStoredNameWithoutMAC_failsTheKeyCheck() async throws {
        let readable = KeyedCipherBuilder.login(id: "t0", name: "Old format", activeKeys: vaultKeys)
        let type0Name = withoutMAC(readable.name)
        // The type-0 name carries no MAC to verify, so it is never decrypted (fix-encstring-validation).
        XCTAssertEqual(try EncString(string: type0Name).encType, .aes256Cbc_B64)
        let stored = RawCipher(
            id: readable.id, organizationId: nil, folderId: nil, type: 1, name: type0Name, notes: nil,
            favorite: false, reprompt: 0, deletedDate: nil, creationDate: nil, revisionDate: readable.revisionDate,
            login: readable.login, card: nil, identity: nil, secureNote: nil, sshKey: nil, fields: nil,
            key: nil, attachments: nil)
        await seed(stored)
        // The cached item still says "editable" (it was read before); the save checks the stored record.
        await sut.populate(
            items: [try mapper.map(raw: readable, vaultKeys: vaultKeys).item],
            folders: [], organizations: [], collections: [], syncedAt: Date())

        XCTAssertThrowsError(try mapper.verifyKey(vaultKeys, against: stored)) { error in
            XCTAssertEqual(error as? CipherMapperError, .fieldDecryptionFailed("name"))
        }
        await assertSaveFails(try draft(of: readable), expecting: { error in
            if case .itemNotEditable(.legacyEncryption) = error { return true }
            return false
        }, "itemNotEditable(legacyEncryption)")
    }

    // The three refusals of design D2 for an item with its own key, through `update`. The read path
    // has its own tests (`EffectiveKeyReadTests`); a regression that fell back to the active key when
    // `effectiveKeys` throws would pass every read test and the cases above.

    func testItemKeyOfType0_throwsItemKeyUnavailable() async throws {
        let itemKey = KeyedCipherBuilder.randomKeys()
        let readable = KeyedCipherBuilder.login(id: "k0", name: "Keyed", activeKeys: vaultKeys, itemKey: itemKey)
        // The same wrapped key without its MAC part, which carries the right IV and ciphertext.
        let stored = try replacingKey(of: readable, with: withoutMAC(try XCTUnwrap(readable.key)))
        XCTAssertEqual(try EncString(string: try XCTUnwrap(stored.key)).encType, .aes256Cbc_B64)
        await seed(stored)

        await assertSaveFails(try draft(of: readable), expecting: isKeyUnavailable, "itemKeyUnavailable")
    }

    func testItemKeyOfTheWrongLength_throwsItemKeyUnavailable() async throws {
        for length in [32, 96] {
            api.updateCipherCallCount = 0
            let id = "len\(length)"
            let itemKey = KeyedCipherBuilder.randomKeys()
            let readable = KeyedCipherBuilder.login(id: id, name: "Keyed", activeKeys: vaultKeys, itemKey: itemKey)
            let short = KeyedCipherBuilder.login(
                id: id, name: "Keyed", activeKeys: vaultKeys, itemKey: itemKey,
                wrappedKeyBytes: Data(repeating: 7, count: length))
            await seed(short)

            await assertSaveFails(try draft(of: readable), expecting: isKeyUnavailable, "itemKeyUnavailable (\(length) bytes)")
        }
    }

    func testKeyedRecordWhoseFieldsAreUnderTheVaultKey_failsTheKeyCheck() async throws {
        // The item key unwraps, but the fields were written with the vault key: the mixed-key shape
        // of rbw#364. The name check under the item key catches it; nothing falls back to the vault key.
        let itemKey = KeyedCipherBuilder.randomKeys()
        let readable = KeyedCipherBuilder.login(id: "mix", name: "Mixed", activeKeys: vaultKeys, itemKey: itemKey)
        let mixed = KeyedCipherBuilder.login(
            id: "mix", name: "Mixed", activeKeys: vaultKeys, itemKey: itemKey, fieldKeys: vaultKeys)
        await seed(mixed)

        await assertSaveFails(try draft(of: readable), expecting: isKeyUnavailable, "itemKeyUnavailable")
    }

    // "No fallback to another key" for an organization item with its own key: the vault key never
    // stands in for the organization key, in either direction.

    func testKeyedOrgItemWrappedUnderTheVaultKey_failsEvenWithTheOrgKeyCached() async throws {
        await orgKeyCache.replaceAll(with: ["org-a": orgAKeys])
        let itemKey = KeyedCipherBuilder.randomKeys()
        let readable = KeyedCipherBuilder.login(
            id: "org-k", name: "Org keyed", organizationId: "org-a", collectionIds: ["col-1"],
            activeKeys: orgAKeys, itemKey: itemKey)
        // The server holds the item key wrapped under the vault key instead of the org key.
        let wrongWrap = KeyedCipherBuilder.login(
            id: "org-k", name: "Org keyed", organizationId: "org-a", collectionIds: ["col-1"],
            activeKeys: orgAKeys, itemKey: itemKey, wrappingKeys: vaultKeys)
        await seed(wrongWrap)

        await assertSaveFails(try draft(of: readable, orgKeys: ["org-a": orgAKeys]),
                              expecting: isKeyUnavailable, "itemKeyUnavailable")
    }

    func testKeyedOrgItemWrappedUnderTheVaultKey_failsWithoutTheOrgKey() async throws {
        let itemKey = KeyedCipherBuilder.randomKeys()
        let readable = KeyedCipherBuilder.login(
            id: "org-k2", name: "Org keyed", organizationId: "org-a", collectionIds: ["col-1"],
            activeKeys: orgAKeys, itemKey: itemKey)
        let wrongWrap = KeyedCipherBuilder.login(
            id: "org-k2", name: "Org keyed", organizationId: "org-a", collectionIds: ["col-1"],
            activeKeys: orgAKeys, itemKey: itemKey, wrappingKeys: vaultKeys)
        await seed(wrongWrap)  // the cache has no org key; the vault key unwraps this item key, and must not be used

        await assertSaveFails(try draft(of: readable, orgKeys: ["org-a": orgAKeys]), expecting: { error in
            if case .organizationKeyUnavailable = error { return true }
            return false
        }, "organizationKeyUnavailable")
    }

    func testStoredWebsiteThatDoesNotDecrypt_failsClosed() async throws {
        // The name verifies, so the key check passes, but a stored website is under another key: the
        // overlay cannot match its unknown keys with the draft's websites, and does not guess.
        let readable = KeyedCipherBuilder.login(id: "w", name: "Site", website: "https://a.example.com", activeKeys: vaultKeys)
        let damaged = KeyedCipherBuilder.login(id: "w", name: "Site", activeKeys: vaultKeys)
        let foreign = KeyedCipherBuilder.encrypt("https://a.example.com", keys: KeyedCipherBuilder.randomKeys())
        let stored = RawCipher(
            id: "w", organizationId: nil, folderId: nil, type: 1, name: damaged.name, notes: nil,
            favorite: false, reprompt: 0, deletedDate: nil, creationDate: nil, revisionDate: readable.revisionDate,
            login: RawLoginData(username: nil, password: nil, uris: [RawURI(uri: foreign, match: nil)], totp: nil),
            card: nil, identity: nil, secureNote: nil, sshKey: nil, fields: nil, key: nil, attachments: nil)
        await seed(stored)

        await assertSaveFails(try draft(of: readable), expecting: isKeyUnavailable, "itemKeyUnavailable")
    }

    func testStoredCustomFieldNameThatDoesNotDecrypt_failsClosed() async throws {
        // Same as a stored website: the name check passes, but a stored field name is under another
        // key, so the overlay cannot tell which stored field a draft field is, and does not guess.
        let readable = KeyedCipherBuilder.login(id: "f", name: "Fields", activeKeys: vaultKeys)
        let foreign = KeyedCipherBuilder.encrypt("Field A", keys: KeyedCipherBuilder.randomKeys())
        let stored = RawCipher(
            id: "f", organizationId: nil, folderId: nil, type: 1, name: readable.name, notes: nil,
            favorite: false, reprompt: 0, deletedDate: nil, creationDate: nil, revisionDate: readable.revisionDate,
            login: readable.login, card: nil, identity: nil, secureNote: nil, sshKey: nil,
            fields: [RawField(type: 0, name: foreign, value: nil, linkedId: nil, extras: ["tag": .string("x")])],
            key: nil, attachments: nil)
        await seed(stored)
        var edited = try draft(of: readable)
        guard case .login(var login) = edited.content else { return XCTFail("expected a login") }
        login.customFields = [DraftCustomField(CustomField(name: "Field A", value: "a", type: .text, linkedId: nil))]
        edited.content = .login(login)

        await assertSaveFails(edited, expecting: isKeyUnavailable, "itemKeyUnavailable")
    }

    // MARK: - The stored record's own shape

    func testStoredRecordWithABlockedShape_throwsItemNotEditable() async throws {
        let readable = KeyedCipherBuilder.login(id: "b", name: "Blob", activeKeys: vaultKeys)
        // The cached item says "editable"; the stored record is a blob.
        var blob = try JSONSerialization.jsonObject(with: JSONEncoder().encode(readable)) as? [String: Any] ?? [:]
        blob["data"] = #"{"format_version":2}"#
        let stored = try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: blob))
        XCTAssertTrue(stored.hasBlobData)
        await seed(stored)
        await sut.populate(
            items: [try mapper.map(raw: readable, vaultKeys: vaultKeys).item],
            folders: [], organizations: [], collections: [], syncedAt: Date())

        await assertSaveFails(try draft(of: readable), expecting: { error in
            if case .itemNotEditable(.unsupportedFormat) = error { return true }
            return false
        }, "itemNotEditable(unsupportedFormat)")
    }

    // MARK: - A failed save changes nothing; retries fail the same way until the cause is gone

    func testFailedSave_changesNothing_andRetriesFailTheSameWay_thenSucceedOnceSeeded() async throws {
        let record = KeyedCipherBuilder.login(id: "c1", name: "Original", username: "u", activeKeys: vaultKeys)
        let item = try mapper.map(raw: record, vaultKeys: vaultKeys).item
        await sut.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
        let edited = try draft(of: record, name: "Edited")
        let draftBefore = edited

        for _ in 0..<2 {
            await assertSaveFails(edited, expecting: isRecordUnavailable, "itemRecordUnavailable")
        }

        let cachedAfterFailure = try await sut.itemDetail(id: "c1")
        XCTAssertEqual(cachedAfterFailure, item, "the item cache is unchanged")
        let storedAfterFailure = await store.record(for: "c1")
        XCTAssertNil(storedAfterFailure, "the store is unchanged")
        XCTAssertEqual(edited, draftBefore, "the draft is unchanged")

        // The cause is gone: the same draft saves.
        await seed(record)
        let saved = try await sut.update(edited)

        XCTAssertEqual(saved.name, "Edited")
        XCTAssertEqual(api.updateCipherCallCount, 1)
    }

    // MARK: - Messages

    func testMessages_matchTheLockAndUnlockWording() {
        XCTAssertEqual(
            VaultError.itemRecordUnavailable.errorDescription,
            "Prizm couldn't load this item's latest saved version. Lock and unlock the vault, then try again.")
        XCTAssertEqual(
            VaultError.itemKeyUnavailable.errorDescription,
            "Prizm couldn't load the encryption key for this item. Lock and unlock the vault, then try again.")
    }
}

/// The edit sheet shows each fail-closed error in its error area, keeps the user's input and stays
/// open, as it does for the organization key error.
@MainActor
final class ItemEditFailClosedErrorTests: XCTestCase {

    private struct FailingEdit: EditVaultItemUseCase {
        let error: VaultError
        func execute(draft: DraftVaultItem) async throws -> VaultItem {
            throw error
        }
    }

    private func assertSheetKeepsInput(
        failingWith error: VaultError, showing message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let item = VaultItem(
            id: "item", name: "Item", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .secureNote(SecureNoteContent(notes: nil, customFields: []))
        )
        let sut = ItemEditViewModel(item: item, useCase: FailingEdit(error: error))
        sut.draft.name = "Edited name"

        sut.save()
        // A generous bound: the save runs off the main actor, and a slow machine must fail with the
        // real cause, not with a mismatch against a message that has not arrived yet.
        let deadline = ContinuousClock.now + .seconds(5)
        while sut.saveError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNotNil(sut.saveError, "timed out waiting for the save error", file: file, line: line)
        XCTAssertEqual(sut.saveError, message, file: file, line: line)
        XCTAssertEqual(sut.draft.name, "Edited name", "The user's input stays", file: file, line: line)
        XCTAssertFalse(sut.isDismissed, "The sheet stays open", file: file, line: line)
    }

    func testSave_itemRecordUnavailable_showsMessageAndKeepsDraft() async throws {
        try await assertSheetKeepsInput(
            failingWith: .itemRecordUnavailable,
            showing: "Prizm couldn't load this item's latest saved version. Lock and unlock the vault, then try again.")
    }

    func testSave_itemKeyUnavailable_showsMessageAndKeepsDraft() async throws {
        try await assertSheetKeepsInput(
            failingWith: .itemKeyUnavailable,
            showing: "Prizm couldn't load the encryption key for this item. Lock and unlock the vault, then try again.")
    }

    func testSave_itemNotEditable_showsMessageAndKeepsDraft() async throws {
        try await assertSheetKeepsInput(
            failingWith: .itemNotEditable(.unsupportedFormat),
            showing: EditBlockReason.unsupportedFormat.userMessage)
    }
}
