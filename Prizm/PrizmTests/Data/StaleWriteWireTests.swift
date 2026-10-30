import XCTest
@testable import Prizm

/// An unlocked vault repository over a fresh record store, with the helpers the stale-write tests
/// share (`StaleWriteWireTests`, `ConflictDetectionTests`).
@MainActor
struct StaleWriteRig {
    let api: MockPrizmAPIClient
    let store: RawCipherStore
    let vault: VaultRepositoryImpl

    static let vaultKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xDE, count: 32),
        macKey:        Data(repeating: 0xAD, count: 32)
    )

    /// The profile id is seeded, so a save gets past `encryptedFor`.
    static func make() async -> StaleWriteRig {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(apiClient: api, crypto: crypto, recordStore: store)
        return StaleWriteRig(api: api, store: store, vault: vault)
    }

    static let orgId = "org-acme"
    static let orgKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xAC, count: 32),
        macKey:        Data(repeating: 0xCE, count: 32)
    )

    /// A rig with one organization item `o1` cached and stored (revision `RepositoryFixtures.revisionDate`),
    /// and the organization key available.
    /// The synced collections are `col-a`, `col-b` and `col-c` (writable) plus `readOnlyCollections`.
    static func makeOrg(collectionIds: [String] = [], readOnlyCollections: [String] = []) async throws -> (StaleWriteRig, VaultItem) {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: [orgId: orgKeys])
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, recordStore: store)
        let item = VaultItem(
            id: "o1", name: "Shared", isFavorite: false, isDeleted: false, creationDate: Date(),
            revisionDate: RepositoryFixtures.revisionDate,
            content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])),
            organizationId: orgId, collectionIds: collectionIds)
        try await RepositoryFixtures.seedRecords(for: [item], in: store, vaultKeys: vaultKeys, orgKeys: [orgId: orgKeys])
        let collections = ["col-a", "col-b", "col-c"].map { OrgCollection(id: $0, organizationId: orgId, name: $0) }
            + readOnlyCollections.map { OrgCollection(id: $0, organizationId: orgId, name: $0, readOnly: true) }
        await vault.populate(items: [item], folders: [], organizations: [], collections: collections, syncedAt: Date())
        return (StaleWriteRig(api: api, store: store, vault: vault), item)
    }

    static func login(_ id: String, name: String = "Login", revisionDate: Date = RepositoryFixtures.revisionDate) -> VaultItem {
        VaultItem(id: id, name: name, isFavorite: false, isDeleted: false, creationDate: Date(),
                  revisionDate: revisionDate,
                  content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])))
    }

    /// Stores the record of `item` with `revision` as its `revisionDate` (nil removes the key), as a
    /// sync of a server that sent that string would leave it.
    ///
    /// `vaultKeys` and `orgKeys` are the keys the stored record is encrypted with; the default is
    /// what the rig's vault holds.
    func storeRecord(of item: VaultItem, revision: String?, vaultKeys: CryptoKeys = StaleWriteRig.vaultKeys,
                     orgKeys: [String: CryptoKeys] = [:]) async throws {
        try await RepositoryFixtures.seedRecords(for: [item], in: store, vaultKeys: vaultKeys, orgKeys: orgKeys)
        let seededRecord = await store.record(for: item.id)
        let seeded = try XCTUnwrap(seededRecord)
        let data = try JSONEncoder().encode(seeded)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let revision { json["revisionDate"] = revision } else { json.removeValue(forKey: "revisionDate") }
        let replaced = try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
        let token = await store.currentGeneration()
        await store.upsert(replaced, ifCurrent: token)
    }

    /// Puts `item` into the cache, as a sync would.
    func cache(_ item: VaultItem) async {
        await vault.populate(items: [item], folders: [Folder(id: "work", name: "Work")],
                             organizations: [], collections: [], syncedAt: Date())
    }

    /// A draft of `item` with another name, so it takes the full PUT path and not /partial.
    /// `revisionDate` replaces the draft's revision when given.
    static func renamed(_ item: VaultItem, revisionDate: Date? = nil) -> DraftVaultItem {
        var draft = DraftVaultItem(item)
        draft.name = "Renamed"
        guard let revisionDate else { return draft }
        return DraftVaultItem(
            id: draft.id, folderId: draft.folderId, name: draft.name, isFavorite: draft.isFavorite,
            isDeleted: draft.isDeleted, creationDate: draft.creationDate, revisionDate: revisionDate,
            content: draft.content, reprompt: draft.reprompt,
            organizationId: draft.organizationId, collectionIds: draft.collectionIds)
    }
}

/// What `VaultRepositoryImpl.update()` does with the revision of the stored server record: refuses
/// an edit when it has no readable revision, compares it with the draft's, leaves Prizm's own
/// operations alone, and sends the stored string as `lastKnownRevisionDate` (openspec change
/// fix-cipher-edit-data-loss, tasks 4.1 to 4.3).
@MainActor
final class StaleWriteWireTests: XCTestCase {

    // MARK: - Tracer: a readable stored revision is required, in any server shape

    func testUpdate_storedRevisionInEachServerShape_reachesThePut() async throws {
        let shapes: [(stored: String, draft: Date)] = [
            ("2026-10-26T10:00:00.123456Z", RepositoryFixtures.revisionDate),
            ("2026-10-26T10:00:00.1230000Z", RepositoryFixtures.revisionDate),
            ("2026-10-26T10:00:00Z", Date(timeIntervalSince1970: 1_793_008_800)),
        ]
        for shape in shapes {
            let rig = await StaleWriteRig.make()
            let item = StaleWriteRig.login("c1", revisionDate: shape.draft)
            try await rig.storeRecord(of: item, revision: shape.stored)

            _ = try await rig.vault.update(StaleWriteRig.renamed(item))

            XCTAssertEqual(rig.api.updateCipherCallCount, 1, "revision \(shape.stored) reaches the PUT")
        }
    }

    func testUpdate_missingEmptyUnparsableOrEpochRevision_throwsAndSendsNothing() async throws {
        let revisions: [String?] = [nil, "", "not-a-date", "1970-01-01T00:00:00.000Z"]
        for revision in revisions {
            let rig = await StaleWriteRig.make()
            let item = StaleWriteRig.login("c1")
            try await rig.storeRecord(of: item, revision: revision)

            do {
                _ = try await rig.vault.update(StaleWriteRig.renamed(item))
                XCTFail("revision \(String(describing: revision)) must refuse the save")
            } catch VaultError.itemRevisionUnavailable {
                // expected
            }

            XCTAssertEqual(rig.api.updateCipherCallCount, 0, "nothing is sent for \(String(describing: revision))")
        }
    }

    func testFolderOnlyChange_withoutStoredRevision_stillUsesPartial() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: nil)
        await rig.cache(item)
        var draft = DraftVaultItem(item)
        draft.folderId = "work"

        let updated = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.partialUpdates.count, 1, "A folder change needs no stored revision")
        XCTAssertEqual(rig.api.updateCipherCallCount, 0)
        XCTAssertEqual(updated.folderId, "work")
    }

    func testRevisionUnavailableMessage_matchesTheCopy() {
        XCTAssertEqual(
            VaultError.itemRevisionUnavailable.errorDescription,
            "Prizm couldn't confirm which version of this item you are editing. Lock and unlock the vault, then try again.")
    }

    // MARK: - Local pre-check: the draft must be based on the stored record

    func testPreCheck_draftOlderThanStoredRecord_throwsConflictWithoutRequest() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        let draft = StaleWriteRig.renamed(item)
        // A sync replaced the stored record after the edit sheet opened.
        try await rig.storeRecord(of: item, revision: "2026-10-26T10:00:05.000000Z")

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("A draft older than the stored record must be refused")
        } catch VaultError.conflict {
            // expected
        }

        XCTAssertEqual(rig.api.updateCipherCallCount, 0, "No request is made")
        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, "2026-10-26T10:00:05.000000Z", "The stored record is not replaced by the draft")
    }

    /// The check is equality, not order: it never depends on which clock is ahead.
    func testPreCheck_draftNewerThanStoredRecord_throwsConflict() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        let draft = StaleWriteRig.renamed(item, revisionDate: item.revisionDate.addingTimeInterval(10))

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("A draft newer than the stored record must be refused too")
        } catch VaultError.conflict {
            // expected
        }

        XCTAssertEqual(rig.api.updateCipherCallCount, 0)
    }

    /// Equal after rounding to whole milliseconds, so the six digits the server sends match the
    /// millisecond a date carries. No server-style tolerance is applied.
    func testPreCheck_sameMillisecond_passes() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: "2026-10-26T10:00:00.123456Z")

        _ = try await rig.vault.update(StaleWriteRig.renamed(item))

        XCTAssertEqual(rig.api.updateCipherCallCount, 1)
    }

    func testPreCheck_oneMillisecondApart_throwsConflict() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: "2026-10-26T10:00:00.124000Z")

        do {
            _ = try await rig.vault.update(StaleWriteRig.renamed(item))
            XCTFail("1 ms apart is another revision")
        } catch VaultError.conflict {
            // expected
        }

        XCTAssertEqual(rig.api.updateCipherCallCount, 0)
    }

    func testPreCheck_runsAfterTheOrganizationCheck() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        var draft = StaleWriteRig.renamed(item, revisionDate: item.revisionDate.addingTimeInterval(10))
        draft.organizationId = "org-other"

        do {
            _ = try await rig.vault.update(draft)
            XCTFail("A draft in another organization must be refused")
        } catch VaultError.itemRecordUnavailable {
            // expected: the organization check comes first
        }

        XCTAssertEqual(rig.api.updateCipherCallCount, 0)
    }

    // MARK: - Order of the refusals: the missing revision comes before the key work

    /// An unlocked vault with no organization key in its cache; the profile id is seeded unless nil.
    private func makeRig(profileId: String? = RepositoryFixtures.profileId) async -> StaleWriteRig {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: StaleWriteRig.vaultKeys)
        crypto.stubbedVaultKeys = StaleWriteRig.vaultKeys
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto,
            profileIds: await RepositoryFixtures.profileIds(seededWith: profileId), recordStore: store)
        return StaleWriteRig(api: api, store: store, vault: vault)
    }

    private func updateError(_ rig: StaleWriteRig, _ draft: DraftVaultItem) async -> VaultError? {
        do {
            _ = try await rig.vault.update(draft)
            return nil
        } catch {
            return error as? VaultError
        }
    }

    /// Design D6 orders the checks: edit block, record, organization, revision refusal, pre-check,
    /// then key work. Each test below makes the revision unreadable AND a later step fail, expects
    /// the revision refusal, then restores the revision and expects the later failure, so the
    /// order is what is tested and not the setup.
    func testMissingRevision_isReportedBeforeAMissingOrganizationKey() async throws {
        let rig = await makeRig()   // no organization key in the vault's cache
        let orgId = "org-acme"
        let item = VaultItem(
            id: "o1", name: "Shared", isFavorite: false, isDeleted: false, creationDate: Date(),
            revisionDate: RepositoryFixtures.revisionDate,
            content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])),
            organizationId: orgId)
        let orgKeys = [orgId: CryptoKeys(encryptionKey: Data(repeating: 0xAC, count: 32),
                                         macKey: Data(repeating: 0xCE, count: 32))]
        let draft = StaleWriteRig.renamed(item)

        try await rig.storeRecord(of: item, revision: nil, orgKeys: orgKeys)
        let withoutRevision = await updateError(rig, draft)
        guard case .itemRevisionUnavailable? = withoutRevision else {
            return XCTFail("Expected itemRevisionUnavailable, got \(String(describing: withoutRevision))")
        }

        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate), orgKeys: orgKeys)
        let withRevision = await updateError(rig, draft)
        guard case .organizationKeyUnavailable? = withRevision else {
            return XCTFail("Expected organizationKeyUnavailable, got \(String(describing: withRevision))")
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 0)
    }

    func testMissingRevision_isReportedBeforeAMissingProfileId() async throws {
        let rig = await makeRig(profileId: nil)
        let item = StaleWriteRig.login("c1")
        let draft = StaleWriteRig.renamed(item)

        try await rig.storeRecord(of: item, revision: nil)
        let withoutRevision = await updateError(rig, draft)
        guard case .itemRevisionUnavailable? = withoutRevision else {
            return XCTFail("Expected itemRevisionUnavailable, got \(String(describing: withoutRevision))")
        }

        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        let withRevision = await updateError(rig, draft)
        guard case .profileIdUnavailable? = withRevision else {
            return XCTFail("Expected profileIdUnavailable, got \(String(describing: withRevision))")
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 0)
    }

    func testMissingRevision_isReportedBeforeAnUnusableItemKey() async throws {
        let rig = await makeRig()
        let item = StaleWriteRig.login("c1")
        let draft = StaleWriteRig.renamed(item)
        // The record is encrypted under keys the vault does not hold, so the key check fails.
        let otherKeys = CryptoKeys(encryptionKey: Data(repeating: 0x11, count: 32), macKey: Data(repeating: 0x22, count: 32))

        try await rig.storeRecord(of: item, revision: nil, vaultKeys: otherKeys)
        let withoutRevision = await updateError(rig, draft)
        guard case .itemRevisionUnavailable? = withoutRevision else {
            return XCTFail("Expected itemRevisionUnavailable, got \(String(describing: withoutRevision))")
        }

        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate), vaultKeys: otherKeys)
        let withRevision = await updateError(rig, draft)
        guard case .itemKeyUnavailable? = withRevision else {
            return XCTFail("Expected itemKeyUnavailable, got \(String(describing: withRevision))")
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 0)
    }

    func testTwoEditsInARow_secondPassesThePreCheck() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        await rig.cache(item)
        // The server's answer carries the new revision; the mock alone would echo a request without one.
        RepositoryFixtures.answerUpdates(of: rig.api, withRevisionString: "2026-10-26T10:00:05.654321Z")

        let saved = try await rig.vault.update(StaleWriteRig.renamed(item))
        var second = DraftVaultItem(saved)
        second.name = "Renamed again"
        _ = try await rig.vault.update(second)

        XCTAssertEqual(rig.api.updateCipherCallCount, 2, "The first answer's revision is stored and cached, so the second draft matches")
    }

    /// When the refresh after Prizm's own operations fails, none of them may make the next edit look
    /// stale: they change cache fields other than the revision and never the stored record. The mock
    /// has no answer for the refresh's GET, so every refresh here fails and the stored record and
    /// the cached revision stay as they were; the refresh that succeeds is `RevisionRefreshTests`.
    func testOwnOperationsWhoseRefreshFails_doNotTripThePreCheck() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        await rig.cache(item)

        try await rig.vault.deleteItem(id: "c1")
        try await rig.vault.restoreItem(id: "c1")
        _ = try await rig.vault.setFavorite(itemId: "c1", isFavorite: true)
        await rig.vault.updateAttachments(
            [Attachment(id: "att-1", fileName: "a.txt", encryptedKey: "2.k|k|k", size: 10,
                        sizeName: "10 B", url: nil, isUploadIncomplete: false)],
            for: "c1")
        let latest = try await rig.vault.itemDetail(id: "c1")
        var draft = DraftVaultItem(latest)
        draft.name = "Renamed after own operations"

        _ = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The edit reaches the server, no false conflict")
        XCTAssertEqual(rig.api.softDeleteCallCount, 1)
        XCTAssertEqual(rig.api.restoreCallCount, 1)
    }

    // MARK: - The wire: the stored revision string goes out unchanged

    // Three server revisions, a minute apart, as the server writes them (six fractional digits).
    private static let r1 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate)
    private static let r2 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(60))
    private static let r3 = RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate.addingTimeInterval(120))

    /// The string is copied, never rebuilt from a date: a date holds milliseconds, the server's
    /// string six fractional digits, and re-formatting would send another revision than the server
    /// holds (and the server compares whole seconds, so a wrong string is a false conflict or a
    /// missed one).
    func testUpdate_sendsTheStoredRevisionStringByteForByte() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: "2026-10-26T10:00:00.123456Z")

        _ = try await rig.vault.update(StaleWriteRig.renamed(item))

        let sent = try XCTUnwrap(rig.api.lastUpdatedCipher)
        XCTAssertEqual(sent.lastKnownRevisionDate, "2026-10-26T10:00:00.123456Z")
        let body = try encodedBody(sent)
        XCTAssertEqual(body["lastKnownRevisionDate"] as? String, "2026-10-26T10:00:00.123456Z",
                       "The encoded body carries the key with the stored string")
    }

    /// A new item has no server copy, so there is nothing to be out of date against.
    func testCreate_sendsNoLastKnownRevisionDate() async throws {
        let rig = await StaleWriteRig.make()

        _ = try await rig.vault.create(DraftVaultItem(StaleWriteRig.login("n1", name: "New")))

        let sent = try XCTUnwrap(rig.api.lastCreatedCipher)
        XCTAssertNil(sent.lastKnownRevisionDate)
        XCTAssertNil(try encodedBody(sent)["lastKnownRevisionDate"], "The key is absent from the create body")
    }

    func testTwoEditsInARow_secondSendsTheFirstResponsesRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: Self.r1)
        await rig.cache(item)
        RepositoryFixtures.answerUpdates(of: rig.api, withRevisionString: "2026-10-26T10:00:05.654321Z")

        _ = try await rig.vault.update(StaleWriteRig.renamed(item))
        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, Self.r1, "The first edit sends the synced revision")
        let latest = try await rig.vault.itemDetail(id: "c1")
        var second = DraftVaultItem(latest)
        second.name = "Renamed again"
        _ = try await rig.vault.update(second)

        XCTAssertEqual(rig.api.updateCipherCallCount, 2, "The second save succeeds")
        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, "2026-10-26T10:00:05.654321Z",
                       "The second edit sends the string the server returned for the first")
    }

    /// The update sends the revision the server gave the item when it restored it, not the synced one.
    func testDeleteRestoreEdit_sendsThePostRestoreRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1")
        try await rig.storeRecord(of: item, revision: Self.r1)
        await rig.cache(item)
        let storedRecord = await rig.store.record(for: "c1")
        let stored = try XCTUnwrap(storedRecord)
        rig.api.getCipherResponses["c1"] = try RepositoryFixtures.withRevision(stored, Self.r2)
        rig.api.restoreCipherResponse = try RepositoryFixtures.withRevision(stored, Self.r3)

        try await rig.vault.deleteItem(id: "c1")
        try await rig.vault.restoreItem(id: "c1")
        let latest = try await rig.vault.itemDetail(id: "c1")
        var draft = DraftVaultItem(latest)
        draft.name = "Renamed after restore"
        _ = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, Self.r3)
    }

    /// Restore and edit within one second differ only in the fraction: the string is still the
    /// restore answer's, byte for byte.
    func testRestoreThenEditInTheSameSecond_sendsTheRestoreRevision() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1").with(isDeleted: true)
        try await rig.storeRecord(of: item, revision: Self.r1)
        await rig.cache(item)
        let sameSecond = RepositoryFixtures.serverRevisionString(
            for: RepositoryFixtures.revisionDate.addingTimeInterval(0.5))
        XCTAssertEqual(sameSecond.prefix(19), Self.r1.prefix(19), "Both revisions are in the same second")
        XCTAssertNotEqual(sameSecond, Self.r1)
        let storedRecord = await rig.store.record(for: "c1")
        let stored = try XCTUnwrap(storedRecord)
        rig.api.restoreCipherResponse = try RepositoryFixtures.withRevision(stored, sameSecond)

        try await rig.vault.restoreItem(id: "c1")
        let latest = try await rig.vault.itemDetail(id: "c1")
        var draft = DraftVaultItem(latest)
        draft.name = "Renamed in the same second"
        _ = try await rig.vault.update(draft)

        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, sameSecond)
    }

    func testOrgEditTwice_secondSendsTheCollectionsRevision() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg()
        RepositoryFixtures.answerUpdates(of: rig.api, withRevisionString: Self.r2, collectionsRevision: Self.r3)
        var first = StaleWriteRig.renamed(item)
        first.collectionIds = ["col-a"]

        _ = try await rig.vault.update(first)
        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, Self.r1)
        let latest = try await rig.vault.itemDetail(id: "o1")
        var second = DraftVaultItem(latest)
        second.name = "Renamed again"
        _ = try await rig.vault.update(second)

        XCTAssertEqual(rig.api.updateCipherCallCount, 2, "The second org edit is sent, not stopped by the pre-check")
        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, Self.r3,
                       "The second edit sends the collections answer's revision, not the item PUT's")
    }

    func testRetryAfterCollectionsFailure_sendsTheStoredRevision() async throws {
        let (rig, item) = try await StaleWriteRig.makeOrg()
        RepositoryFixtures.answerUpdates(of: rig.api, withRevisionString: Self.r2, getRevision: Self.r3)
        rig.api.updateCipherCollectionsShouldThrow = APIError.httpError(statusCode: 500, body: "")
        var draft = StaleWriteRig.renamed(item)
        draft.collectionIds = ["col-a"]
        do {
            _ = try await rig.vault.update(draft)
            XCTFail("The collection update fails")
        } catch VaultError.collectionChangeNotSaved {
            // expected
        }
        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, Self.r1)

        rig.api.updateCipherCollectionsShouldThrow = nil
        var retry = draft
        let cached = try await rig.vault.itemDetail(id: "o1")
        retry.revisionDate = cached.revisionDate
        _ = try await rig.vault.update(retry)

        XCTAssertEqual(rig.api.updateCipherCallCount, 2, "The retry is a full PUT")
        XCTAssertEqual(rig.api.lastUpdatedCipher?.lastKnownRevisionDate, Self.r3,
                       "It carries the revision the stored record holds after the refresh")
    }

    private func encodedBody(_ cipher: RawCipher) throws -> [String: Any] {
        let data = try JSONEncoder().encode(cipher)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
