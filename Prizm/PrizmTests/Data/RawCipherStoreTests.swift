import XCTest
@testable import Prizm

/// The in-memory store of the last server record per item: filled by sync, create and update,
/// emptied with the vault, and fenced so that work finishing after a lock cannot refill it.
@MainActor
final class RawCipherStoreTests: XCTestCase {

    private let vaultKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xDE, count: 32),
        macKey:        Data(repeating: 0xAD, count: 32)
    )

    private let passkeyCipherId = "00000000-0000-4000-8000-000000000003"

    // MARK: - Helpers

    /// One store and one profile-id holder shared by a real sync and a real vault repository, as
    /// `AppContainer` wires them. The crypto mock is unlocked.
    private struct Rig {
        let api: MockPrizmAPIClient
        let crypto: MockPrizmCryptoService
        let store: RawCipherStore
        let profileIds: ProfileIdCache
        let vaultKeyCache: VaultKeyCache
        let orgKeyCache: OrgKeyCache
        let vault: VaultRepositoryImpl
        let sync: SyncRepositoryImpl
    }

    /// `seedProfileId` nil leaves the holder empty, so only a sync fills it; saves need one.
    private func makeRig(seedProfileId: String? = nil, orgKeyCache: OrgKeyCache = OrgKeyCache()) async -> Rig {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        let store = RawCipherStore()
        let profileIds = await RepositoryFixtures.profileIds(seededWith: seedProfileId)
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, profileIds: profileIds, recordStore: store)
        let vaultKeyCache = VaultKeyCache()
        let sync = await RepositoryFixtures.syncRepository(
            apiClient: api, crypto: crypto, vaultRepository: vault, vaultKeyCache: vaultKeyCache,
            orgKeyCache: orgKeyCache, profileIds: profileIds, recordStore: store)
        return Rig(api: api, crypto: crypto, store: store, profileIds: profileIds, vaultKeyCache: vaultKeyCache,
                   orgKeyCache: orgKeyCache, vault: vault, sync: sync)
    }

    private func goldenSyncResponse() throws -> SyncResponse {
        try JSONDecoder().decode(SyncResponse.self, from: FixtureLoader.data(named: "sync-golden-1.37.4"))
    }

    private func vaultItem(_ id: String) -> VaultItem {
        VaultItem(id: id, name: id, isFavorite: false, isDeleted: false, creationDate: Date(),
                  revisionDate: Date(), content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
    }

    private func rawCipher(_ id: String, revisionDate: String? = nil) -> RawCipher {
        RawCipher(
            id: id, organizationId: nil, folderId: nil, type: 1, name: "2.x|y|z", notes: nil,
            favorite: false, reprompt: nil, deletedDate: nil, creationDate: nil,
            revisionDate: revisionDate, login: nil, card: nil, identity: nil, secureNote: nil,
            sshKey: nil, fields: nil, key: nil, attachments: nil
        )
    }

    private func loginDraft(id: String, name: String) -> DraftVaultItem {
        DraftVaultItem(
            id: id, name: name, isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: RepositoryFixtures.revisionDate,
            content: .login(DraftLoginContent(LoginContent(
                username: nil, password: nil, uris: [], totp: nil, notes: nil, customFields: []
            ))),
            reprompt: 0
        )
    }

    private func trashedItem(_ id: String) -> VaultItem {
        VaultItem(id: id, name: id, isFavorite: false, isDeleted: true, creationDate: Date(),
                  revisionDate: Date(), content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))
    }

    /// The same cipher with another `revisionDate`, so a test can tell the server's answer from the
    /// request it echoes.
    private func withRevisionDate(_ cipher: RawCipher, _ date: String) throws -> RawCipher {
        let data = try JSONEncoder().encode(cipher)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["revisionDate"] = date
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A stored record that holds what Prizm does not model: password history and a passkey.
    /// Its name is a real type-2 EncString under `vaultKeys`, as a server record is, so a save built
    /// over it can check the key against it.
    private func richRecord(_ id: String) throws -> RawCipher {
        let name = try CipherMapper().toNewRawCipher(DraftVaultItem(vaultItem(id)), encryptedWith: vaultKeys, encryptedFor: RepositoryFixtures.profileId).name
        return RawCipher(
            id: id, organizationId: nil, folderId: nil, type: 1, name: name, notes: nil,
            favorite: false, reprompt: nil, deletedDate: nil, creationDate: nil,
            revisionDate: RepositoryFixtures.serverRevisionString(for: RepositoryFixtures.revisionDate),
            login: RawLoginData(username: nil, password: nil, uris: nil, totp: nil,
                                extras: ["fido2Credentials": .array([.object(["credentialId": .string("2.cred")])])]),
            card: nil, identity: nil, secureNote: nil, sshKey: nil, fields: nil, key: nil, attachments: nil,
            passwordHistory: .array([.object(["password": .string("2.old")])])
        )
    }

    private func seed(_ store: RawCipherStore, _ ciphers: [RawCipher]) async {
        let token = await store.currentGeneration()
        await store.replaceAll(ciphers, ifCurrent: token)
    }

    // MARK: - Tracer: sync fills one shared store, clearVault empties it

    func testSyncFillsTheSharedStore_andClearVaultEmptiesIt() async throws {
        let rig = await makeRig()
        rig.api.syncResponse = try goldenSyncResponse()
        rig.crypto.stubbedDecryptList = [vaultItem("a"), vaultItem("b")]
        rig.crypto.stubbedFailedCount = 4

        _ = try await rig.sync.sync(progress: { _ in })

        // Ciphers that fail to decrypt are stored too: the server's record is what a later edit
        // sends back, whether or not Prizm could read it.
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 6)
        let passkey = await rig.store.record(for: passkeyCipherId)
        XCTAssertNotNil(passkey?.login?.extras["fido2Credentials"], "The passkey login keeps its credentials")

        await rig.vault.clearVault()

        let countAfterClear = await rig.store.count
        XCTAssertEqual(countAfterClear, 0)
    }

    func testSyncStillRunningAtLock_doesNotRefillTheStore() async throws {
        let rig = await makeRig()
        rig.api.syncResponse = try goldenSyncResponse()
        rig.crypto.stubbedDecryptList = [vaultItem("a"), vaultItem("b")]
        // The crypto mock stays unlocked, so `ensureStillUnlocked()` passes (this is also what a
        // lock followed by an unlock looks like): only the store's token can stop the write.
        let vault = rig.vault
        rig.api.whileFetchingSync = { await vault.clearVault() }

        do {
            _ = try await rig.sync.sync(progress: { _ in })
            XCTFail("A sync that was cleared while it ran must throw")
        } catch PrizmCryptoServiceError.vaultLocked {
            // expected: the same error a lock during the sync produces
        }

        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "A late sync must not refill the store")
        let items = try await rig.vault.allItems()
        XCTAssertTrue(items.isEmpty, "populate never ran")
        let profileId = await rig.profileIds.current()
        XCTAssertNil(profileId, "The profile id is not set by a refused sync")
    }

    /// The sync of an earlier session also writes the key caches, and a lock followed by an unlock
    /// passes the unlocked check: the old answer must not replace the keys the next session holds.
    func testSyncStillRunningAtLock_doesNotOverwriteTheNextSessionsKeyCaches() async throws {
        let rig = await makeRig()
        rig.api.syncResponse = try goldenSyncResponse()
        rig.crypto.stubbedDecryptList = [vaultItem("a")]
        let vault = rig.vault
        let orgKeys = rig.orgKeyCache
        let itemKeys = rig.vaultKeyCache
        let nextSessionOrgKeys = ["next-org": vaultKeys]
        // By the time the old answer arrives, the next session's sync has filled the caches.
        rig.api.whileFetchingSync = {
            await vault.clearVault()
            await orgKeys.replaceAll(with: nextSessionOrgKeys)
            await itemKeys.populate(sources: ["next-cipher": .itemKey(Data(repeating: 0x33, count: 64))])
        }

        do {
            _ = try await rig.sync.sync(progress: { _ in })
            XCTFail("A sync that was cleared while it ran must throw")
        } catch PrizmCryptoServiceError.vaultLocked {
            // expected
        }

        let orgKeysAfter = await orgKeys.snapshot()
        XCTAssertEqual(Set(orgKeysAfter.keys), ["next-org"], "The discarded sync must not replace the org keys")
        let itemKeyAfter = await itemKeys.key(for: "next-cipher")
        XCTAssertNotNil(itemKeyAfter, "The discarded sync must not replace the per-item keys")
    }

    /// The same for an answer without organizations, which clears the org keys of leavers.
    func testSyncWithoutOrganizationsStillRunningAtLock_doesNotClearTheNextSessionsOrgKeys() async throws {
        let rig = await makeRig()
        let golden = try goldenSyncResponse()
        rig.api.syncResponse = SyncResponse(profile: golden.profile, ciphers: golden.ciphers, folders: golden.folders)
        rig.crypto.stubbedDecryptList = [vaultItem("a")]
        let vault = rig.vault
        let orgKeys = rig.orgKeyCache
        let nextSessionOrgKeys = ["next-org": vaultKeys]
        rig.api.whileFetchingSync = {
            await vault.clearVault()
            await orgKeys.replaceAll(with: nextSessionOrgKeys)
        }

        _ = try? await rig.sync.sync(progress: { _ in })

        let orgKeysAfter = await orgKeys.snapshot()
        XCTAssertEqual(Set(orgKeysAfter.keys), ["next-org"], "The discarded sync must not clear the org keys")
    }

    /// The profile id is written after the store, with a hop in between; a stale token refuses it.
    func testProfileIdIsNotSetWithAStaleToken() async {
        let ids = ProfileIdCache()
        let stale = RawCipherStore()
        let token = stale.currentGeneration()
        stale.invalidate()

        let wrote = await ids.set("profile-1", ifCurrent: { stale.isCurrent(token) })

        XCTAssertFalse(wrote)
        let current = await ids.current()
        XCTAssertNil(current, "A refused write leaves no id")
    }

    func testProfileIdIsSetWithACurrentToken() async {
        let ids = ProfileIdCache()
        let store = RawCipherStore()
        let token = store.currentGeneration()

        let wrote = await ids.set("profile-1", ifCurrent: { store.isCurrent(token) })

        XCTAssertTrue(wrote)
        let current = await ids.current()
        XCTAssertEqual(current, "profile-1")
    }

    /// Holds the first caller until released; later callers pass. Lets a test park a request that is
    /// "in flight" and act while it waits.
    private actor Gate {
        private var calls = 0
        private var held = false
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func holdFirstCaller() async {
            calls += 1
            guard calls == 1 else { return }
            held = true
            if released { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        /// True once the first caller is parked; gives up after `timeout` so a run that never reaches
        /// the gate (a failure before the request) fails the test instead of hanging it.
        func waitUntilHeld(timeout: Duration = .seconds(5)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while !held, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return held
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters = []
        }
    }

    /// A lock followed by an unlock while a sync runs: the old sync is discarded, and it must not
    /// make the unlock's own sync fail with `syncInProgress`, or neither would fill the vault.
    func testSyncAfterLockAndUnlock_isNotBlockedByTheDiscardedOne() async throws {
        let rig = await makeRig()
        rig.api.syncResponse = try goldenSyncResponse()
        rig.crypto.stubbedDecryptList = [vaultItem("a"), vaultItem("b")]
        let gate = Gate()
        rig.api.whileFetchingSync = { await gate.holdFirstCaller() }

        let sync = rig.sync
        let old = Task { try await sync.sync(progress: { _ in }) }
        let parked = await gate.waitUntilHeld()
        guard parked else {
            await gate.release()
            return XCTFail("timed out waiting for the first sync to reach the fetch")
        }

        // Lock and unlock (the crypto mock stays unlocked, which is what the unlock looks like).
        await rig.vault.clearVault()
        let result = try await rig.sync.sync(progress: { _ in })
        XCTAssertEqual(result.totalCiphers, 6, "The new session's sync ran")

        await gate.release()
        switch await old.result {
        case .success: XCTFail("The sync of the cleared session must be discarded")
        case .failure(let error): XCTAssertEqual(error as? PrizmCryptoServiceError, .vaultLocked)
        }

        let items = try await rig.vault.allItems()
        XCTAssertEqual(Set(items.map(\.id)), ["a", "b"], "The vault holds what the new sync delivered")
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 6)
    }

    func testStaleTokens_areRefusedAfterClear() async {
        let store = RawCipherStore()
        let stale = await store.currentGeneration()
        await store.clear()

        let replaced = await store.replaceAll([rawCipher("a")], ifCurrent: stale)
        let upserted = await store.upsert(rawCipher("b"), ifCurrent: stale)
        let removed = await store.remove(ids: ["a"], ifCurrent: stale)
        let countAfterStale = await store.count

        XCTAssertFalse(replaced)
        XCTAssertFalse(upserted)
        XCTAssertFalse(removed)
        XCTAssertEqual(countAfterStale, 0, "Refused writes change nothing")

        let fresh = await store.currentGeneration()
        let replacedFresh = await store.replaceAll([rawCipher("a")], ifCurrent: fresh)
        let upsertedFresh = await store.upsert(rawCipher("b"), ifCurrent: fresh)
        let countAfterUpsert = await store.count
        let removedFresh = await store.remove(ids: ["a"], ifCurrent: fresh)
        let countAfterRemove = await store.count

        XCTAssertTrue(replacedFresh)
        XCTAssertTrue(upsertedFresh)
        XCTAssertEqual(countAfterUpsert, 2)
        XCTAssertTrue(removedFresh)
        XCTAssertEqual(countAfterRemove, 1)
    }

    // MARK: - Seeding helper (the stored record a save is built over)

    private let acmeKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xAC, count: 32),
        macKey:        Data(repeating: 0xCE, count: 32)
    )

    private func personalLogin(_ id: String, name: String) -> VaultItem {
        VaultItem(id: id, name: name, isFavorite: false, isDeleted: false, creationDate: Date(),
                  revisionDate: RepositoryFixtures.revisionDate,
                  content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])))
    }

    private func orgNote(_ id: String, name: String, organizationId: String) -> VaultItem {
        VaultItem(id: id, name: name, isFavorite: false, isDeleted: false, creationDate: Date(),
                  revisionDate: RepositoryFixtures.revisionDate, content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
                  organizationId: organizationId)
    }

    func testSeedRecords_storesRecordsThatMapBackToTheirItems() async throws {
        let store = RawCipherStore()
        let items = [
            personalLogin("p1", name: "Personal login"),
            orgNote("o1", name: "Org note", organizationId: "org-acme")
        ]

        try await RepositoryFixtures.seedRecords(
            for: items, in: store, vaultKeys: vaultKeys, orgKeys: ["org-acme": acmeKeys])

        for item in items {
            let record = await store.record(for: item.id)
            let stored = try XCTUnwrap(record, "A record is stored for \(item.id)")
            let mapped = try CipherMapper().map(raw: stored, vaultKeys: vaultKeys, orgKeys: ["org-acme": acmeKeys]).item
            XCTAssertEqual(mapped.name, item.name)
            XCTAssertEqual(mapped.organizationId, item.organizationId)
        }
    }

    func testSeedRecords_stampsTheItemsRevisionInTheServerFormat() async throws {
        let store = RawCipherStore()
        let personal = personalLogin("p1", name: "Personal login")
        let org = orgNote("o1", name: "Org note", organizationId: "org-acme")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        try await RepositoryFixtures.seedRecords(
            for: [personal, org], in: store, vaultKeys: vaultKeys, orgKeys: ["org-acme": acmeKeys])

        for item in [personal, org] {
            let record = await store.record(for: item.id)
            let stored = try XCTUnwrap(record, "A record is stored for \(item.id)")
            let revision = try XCTUnwrap(stored.revisionDate, "The record of \(item.id) carries a revision")
            XCTAssertNotNil(
                revision.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$"#, options: .regularExpression),
                "The revision is in the server's shape: \(revision)")
            XCTAssertTrue(revision.hasSuffix(".123000Z"), "The fixed millisecond is written as .123000Z: \(revision)")
            let parsed = try XCTUnwrap(formatter.date(from: revision), "The revision parses back: \(revision)")
            XCTAssertEqual(
                (parsed.timeIntervalSince1970 * 1000).rounded(),
                (item.revisionDate.timeIntervalSince1970 * 1000).rounded(),
                "The revision parses back to the item's revision at millisecond resolution")
            let mapped = try CipherMapper().map(raw: stored, vaultKeys: vaultKeys, orgKeys: ["org-acme": acmeKeys]).item
            XCTAssertEqual(mapped.name, item.name)
            XCTAssertEqual(mapped.organizationId, item.organizationId)
        }
    }

    func testSeedRecords_subMillisecondRevision_throws() async throws {
        let store = RawCipherStore()
        let item = VaultItem(
            id: "p-sub-ms", name: "Sub millisecond", isFavorite: false, isDeleted: false, creationDate: Date(),
            revisionDate: Date(timeIntervalSince1970: 1_793_008_800.1234),
            content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))

        do {
            try await RepositoryFixtures.seedRecords(for: [item], in: store, vaultKeys: vaultKeys)
            XCTFail("A revision that is not a whole millisecond must be refused")
        } catch let error as RepositoryFixtures.SeedError {
            XCTAssertTrue(error.description.contains("p-sub-ms"), "The error names the item: \(error.description)")
        }
        let stored = await store.record(for: "p-sub-ms")
        XCTAssertNil(stored, "Nothing is stored for a refused item")
    }

    func testSeedRecords_wholeMillisecondWithFloatingPointError_isAccepted() async throws {
        let store = RawCipherStore()
        // A date built from the reference date, as a parsed revision is: 814_701_600.002 + 978_307_200
        // is 1_793_008_800.0019999 in a Double, so its millisecond count is not an exact integer.
        let date = Date(timeIntervalSinceReferenceDate: 814_701_600.002)
        let milliseconds = date.timeIntervalSince1970 * 1000
        XCTAssertNotEqual(milliseconds, milliseconds.rounded(), "The date is the floating-point case this test is about")
        let item = VaultItem(
            id: "p-fp", name: "Floating point", isFavorite: false, isDeleted: false, creationDate: Date(),
            revisionDate: date, content: .secureNote(SecureNoteContent(notes: nil, customFields: [])))

        try await RepositoryFixtures.seedRecords(for: [item], in: store, vaultKeys: vaultKeys)

        let stored = await store.record(for: "p-fp")
        let revision = try XCTUnwrap(stored?.revisionDate)
        XCTAssertTrue(revision.hasSuffix(".002000Z"), "The nearest millisecond is written, not the one below: \(revision)")
    }

    /// A setup failure of the update-answer helper is reported where it happens. Silently leaving
    /// the mock's bare echo (no revision) in place would fail a later save with
    /// `itemRevisionUnavailable`, far from the cause.
    func testAnswerUpdates_withoutARecordedRequest_reportsTheSetupFailure() async {
        let api = MockPrizmAPIClient()
        RepositoryFixtures.answerUpdates(of: api, withRevisionString: "2026-10-26T10:00:00.123456Z")
        XCTAssertNil(api.lastUpdatedCipher, "No update request has been recorded yet")

        XCTExpectFailure("The helper has no request to answer and says so")
        await api.whileUpdatingCipher?()

        XCTAssertNil(api.updateCipherResponse, "Nothing is stamped without a request")
    }

    func testSeedRecords_orgItemWithoutItsKey_throws() async throws {
        let store = RawCipherStore()

        do {
            try await RepositoryFixtures.seedRecords(
                for: [orgNote("o1", name: "Org note", organizationId: "org-acme")],
                in: store, vaultKeys: vaultKeys, orgKeys: [:])
            XCTFail("Seeding an org item without its key must throw, never fall back to the vault key")
        } catch is RepositoryFixtures.SeedError {
            // expected
        }
        let stored = await store.record(for: "o1")
        XCTAssertNil(stored, "Nothing is stored when the key is missing")
    }

    // MARK: - Hooks: update, create, permanent delete

    func testUpdate_storesThePutResponse() async throws {
        let rig = await makeRig(seedProfileId: RepositoryFixtures.profileId)
        // The save is built over the stored record; no cached item for "c1", so the full PUT path runs
        // (an unchanged item would use /partial).
        try await RepositoryFixtures.seedRecords(
            for: [personalLogin("c1", name: "Original")], in: rig.store, vaultKeys: vaultKeys)
        let draft = loginDraft(id: "c1", name: "Renamed")
        // The server's answer to a save carries a revision, so the second save below has one to
        // check; the mock alone would echo the request, which has none.
        RepositoryFixtures.answerUpdatesWithRevision(of: rig.api)
        _ = try await rig.vault.update(draft)
        let firstStored = await rig.store.record(for: "c1")
        XCTAssertNotNil(firstStored, "The server's answer is stored")

        rig.api.whileUpdatingCipher = nil
        let answer = try withRevisionDate(try XCTUnwrap(rig.api.lastUpdatedCipher), "2026-10-27T10:00:00.000Z")
        rig.api.updateCipherResponse = answer
        _ = try await rig.vault.update(draft)

        let stored = await rig.store.record(for: "c1")
        XCTAssertEqual(stored?.revisionDate, "2026-10-27T10:00:00.000Z", "The response, not the request, is stored")
    }

    func testUpdate_sendsThePreservedValuesOfTheStoredRecord() async throws {
        let rig = await makeRig(seedProfileId: RepositoryFixtures.profileId)
        let stored = try richRecord("c1")
        await seed(rig.store, [stored])

        _ = try await rig.vault.update(loginDraft(id: "c1", name: "Renamed"))

        // A save is built over the stored record: what Prizm does not model goes back as received.
        let sent = try XCTUnwrap(rig.api.lastUpdatedCipher)
        XCTAssertEqual(sent.passwordHistory, stored.passwordHistory)
        XCTAssertEqual(sent.login?.extras["fido2Credentials"], stored.login?.extras["fido2Credentials"])
        XCTAssertNotNil(sent.login?.extras["fido2Credentials"])
    }

    func testCreatePersonalAndOrg_storeTheCreatedCipher() async throws {
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": CryptoKeys(
            encryptionKey: Data(repeating: 0x33, count: 32), macKey: Data(repeating: 0x44, count: 32))])
        let rig = await makeRig(seedProfileId: RepositoryFixtures.profileId, orgKeyCache: orgKeyCache)

        _ = try await rig.vault.create(loginDraft(id: "n1", name: "Personal"))
        var org = loginDraft(id: "o1", name: "Shared")
        org.organizationId = "org-1"
        org.collectionIds = ["col-a"]
        _ = try await rig.vault.create(org)

        let personal = await rig.store.record(for: "n1")
        let shared = await rig.store.record(for: "o1")
        XCTAssertEqual(personal?.encryptedFor, RepositoryFixtures.profileId)
        XCTAssertEqual(shared?.organizationId, "org-1")
        XCTAssertEqual(rig.api.createCipherCallCount, 1)
        XCTAssertEqual(rig.api.createOrgCipherCallCount, 1)
    }

    func testPermanentDelete_removesTheRecord() async throws {
        let rig = await makeRig()
        await rig.vault.populate(items: [trashedItem("t1"), trashedItem("t2")], folders: [],
                                 organizations: [], collections: [], syncedAt: Date())
        await seed(rig.store, [rawCipher("t1"), rawCipher("t2")])

        try await rig.vault.permanentDeleteItem(id: "t1")

        let gone = await rig.store.record(for: "t1")
        let kept = await rig.store.record(for: "t2")
        XCTAssertNil(gone)
        XCTAssertNotNil(kept)
    }

    func testEmptyTrash_removesOnlyTheRecordsOfSucceededChunks() async throws {
        let rig = await makeRig()
        rig.api.bulkDeleteFailsOnCall = 1  // the second chunk of 500 fails, as in EmptyTrashRepositoryTests
        let trashed = (0..<1_200).map { trashedItem("t\($0)") }
        let active = vaultItem("a0")
        await rig.vault.populate(items: trashed + [active], folders: [], organizations: [],
                                 collections: [], syncedAt: Date())
        await seed(rig.store, (trashed.map(\.id) + [active.id]).map { rawCipher($0) })

        do {
            try await rig.vault.permanentDeleteItems(ids: trashed.map(\.id))
            XCTFail("Expected the failing chunk's error")
        } catch is PermanentDeleteError {}

        let first = await rig.store.record(for: "t0")
        let failedChunk = await rig.store.record(for: "t500")
        let last = await rig.store.record(for: "t1199")
        let activeRecord = await rig.store.record(for: "a0")
        let storedCount = await rig.store.count
        XCTAssertNil(first, "Chunk 1 went through")
        XCTAssertNotNil(failedChunk, "Chunk 2 failed, its records stay")
        XCTAssertNil(last, "Chunk 3 went through")
        XCTAssertNotNil(activeRecord)
        XCTAssertEqual(storedCount, 501)
    }

    // MARK: - Races: a save that finishes after the vault was cleared

    func testUpdateCompletingAfterLock_doesNotRefillTheStore() async throws {
        let rig = await makeRig(seedProfileId: RepositoryFixtures.profileId)
        let vault = rig.vault
        rig.api.whileUpdatingCipher = { await vault.clearVault() }
        try await RepositoryFixtures.seedRecords(
            for: [personalLogin("c1", name: "Original")], in: rig.store, vaultKeys: vaultKeys)

        do {
            _ = try await rig.vault.update(loginDraft(id: "c1", name: "Renamed"))
            XCTFail("An update finishing after the clear must throw")
        } catch VaultError.vaultLocked {
            // expected: no success callback can run for a save that throws
        }

        XCTAssertEqual(rig.api.updateCipherCallCount, 1)
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "An update finishing after the clear must not refill the store")
        let cached = try await rig.vault.allItems()
        XCTAssertTrue(cached.isEmpty, "An update finishing after the clear must not cache the item")
    }

    func testCreateCompletingAfterLock_doesNotRefillTheStore() async throws {
        let rig = await makeRig(seedProfileId: RepositoryFixtures.profileId)
        let vault = rig.vault
        rig.api.whileCreatingCipher = { await vault.clearVault() }

        do {
            _ = try await rig.vault.create(loginDraft(id: "n1", name: "New"))
            XCTFail("A create finishing after the clear must throw")
        } catch VaultError.vaultLocked {
            // expected
        }

        XCTAssertEqual(rig.api.createCipherCallCount, 1)
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "A create finishing after the clear must not refill the store")
        let cached = try await rig.vault.allItems()
        XCTAssertTrue(cached.isEmpty, "A create finishing after the clear must not cache the item")
    }

    /// Lock, then a sync of the next session stores a record for the same id, all while the old
    /// session's permanent delete waits for the server. The delete belongs to the old session, so it
    /// must not remove the new record.
    func testPermanentDeleteCompletingAfterLock_doesNotRemoveTheNewSessionsRecord() async throws {
        let rig = await makeRig()
        await rig.vault.populate(items: [trashedItem("t1")], folders: [], organizations: [],
                                 collections: [], syncedAt: Date())
        await seed(rig.store, [rawCipher("t1", revisionDate: "old")])
        let vault = rig.vault
        let store = rig.store
        let newRecord = rawCipher("t1", revisionDate: "new")
        rig.api.whileDeletingCipher = {
            await vault.clearVault()
            let token = await store.currentGeneration()
            await store.replaceAll([newRecord], ifCurrent: token)
        }

        try await rig.vault.permanentDeleteItem(id: "t1")

        XCTAssertEqual(rig.api.permanentDeleteCallCount, 1)
        let kept = await rig.store.record(for: "t1")
        XCTAssertEqual(kept?.revisionDate, "new", "A delete of the cleared session must not touch the new session's record")
    }

    func testEmptyTrashCompletingAfterLock_doesNotRemoveTheNewSessionsRecords() async throws {
        let rig = await makeRig()
        await rig.vault.populate(items: [trashedItem("t1"), trashedItem("t2")], folders: [], organizations: [],
                                 collections: [], syncedAt: Date())
        await seed(rig.store, [rawCipher("t1", revisionDate: "old"), rawCipher("t2", revisionDate: "old")])
        let vault = rig.vault
        let store = rig.store
        let newRecords = [rawCipher("t1", revisionDate: "new"), rawCipher("t2", revisionDate: "new")]
        rig.api.whileDeletingCiphers = {
            await vault.clearVault()
            let token = await store.currentGeneration()
            await store.replaceAll(newRecords, ifCurrent: token)
        }

        try await rig.vault.permanentDeleteItems(ids: ["t1", "t2"])

        XCTAssertEqual(rig.api.bulkDeleteCalls.count, 1)
        let first = await rig.store.record(for: "t1")
        let second = await rig.store.record(for: "t2")
        XCTAssertEqual(first?.revisionDate, "new", "A bulk delete of the cleared session must not touch the new session's records")
        XCTAssertEqual(second?.revisionDate, "new")
    }

    // MARK: - Redaction: nothing prints a value

    /// Every way a value can reach a log or a debugger: `String(describing:)`, `String(reflecting:)`,
    /// interpolation and `dump`.
    private func renderings(of value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), "\(value)", dumped]
    }

    private func assertNoSecret(_ value: Any, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in renderings(of: value) {
            XCTAssertFalse(text.contains("SECRET"), "\(label) printed a value: \(text.prefix(80))", file: file, line: line)
        }
    }

    /// A cipher with the marker in every kind of field the wire model holds.
    private func secretCipher() -> RawCipher {
        let uri = RawURI(uri: "2.SECRET-uri", match: 0, extras: ["x": .string("SECRET")])
        let login = RawLoginData(
            username: "2.SECRET-user", password: "2.SECRET-pw", uris: [uri], totp: "2.SECRET-totp",
            extras: ["fido2Credentials": .array([.object(["credentialId": .string("SECRET")])])])
        let card = RawCardData(cardholderName: "2.SECRET", brand: "2.SECRET", number: "2.SECRET",
                               expMonth: "2.SECRET", expYear: "2.SECRET", code: "2.SECRET",
                               extras: ["x": .string("SECRET")])
        let identity = RawIdentityData(
            title: "2.SECRET", firstName: "2.SECRET", middleName: nil, lastName: "2.SECRET", address1: "2.SECRET",
            address2: nil, address3: nil, city: "2.SECRET", state: nil, postalCode: nil, country: nil,
            company: nil, email: "2.SECRET", phone: nil, ssn: "2.SECRET", username: nil, passportNumber: nil,
            licenseNumber: nil, extras: ["x": .string("SECRET")])
        let sshKey = RawSSHKeyData(privateKey: "2.SECRET", publicKey: "2.SECRET", keyFingerprint: "2.SECRET",
                                   extras: ["x": .string("SECRET")])
        let field = RawField(type: 0, name: "2.SECRET", value: "2.SECRET", linkedId: nil,
                             extras: ["x": .string("SECRET")])
        return RawCipher(
            id: "c1", organizationId: nil, folderId: nil, type: 1, name: "2.SECRET-name", notes: "2.SECRET-notes",
            favorite: false, reprompt: nil, deletedDate: nil, creationDate: nil, revisionDate: nil,
            login: login, card: card, identity: identity, secureNote: RawSecureNoteData(type: 0), sshKey: sshKey,
            fields: [field], key: "2.SECRET-key", attachments: nil,
            passwordHistory: .array([.object(["password": .string("SECRET")])])
        )
    }

    func testRawCipherAndNestedStructs_printNoValues() throws {
        let cipher = secretCipher()
        assertNoSecret(cipher, "RawCipher")
        assertNoSecret(try XCTUnwrap(cipher.login), "RawLoginData")
        assertNoSecret(try XCTUnwrap(cipher.login?.uris?.first), "RawURI")
        assertNoSecret(try XCTUnwrap(cipher.card), "RawCardData")
        assertNoSecret(try XCTUnwrap(cipher.identity), "RawIdentityData")
        assertNoSecret(try XCTUnwrap(cipher.sshKey), "RawSSHKeyData")
        assertNoSecret(try XCTUnwrap(cipher.fields?.first), "RawField")
        assertNoSecret(try XCTUnwrap(cipher.secureNote), "RawSecureNoteData")
        XCTAssertEqual(String(describing: cipher), "RawCipher(redacted)")
    }

    func testJSONValue_printsNoValues() {
        assertNoSecret(JSONValue.string("SECRET"), "JSONValue.string")
        assertNoSecret(JSONValue.array([.string("SECRET"), .int(7)]), "JSONValue.array")
        assertNoSecret(JSONValue.object(["k": .string("SECRET")]), "JSONValue.object")
        XCTAssertEqual(String(describing: JSONValue.string("SECRET")), "JSONValue(redacted)")
    }

    func testStore_printsNoValues() async {
        let store = RawCipherStore()
        await seed(store, [secretCipher()])

        assertNoSecret(store, "RawCipherStore")
        XCTAssertEqual(String(describing: store), "RawCipherStore(redacted)")
        XCTAssertEqual(String(reflecting: store), "RawCipherStore(redacted)")
    }
}
