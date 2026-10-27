import XCTest
@testable import Prizm

/// What a lock does to work that is still in flight: a save or a sync result that arrives after
/// `clearVault()` must not put plaintext, a record or an item back into the repository (openspec
/// change fix-cipher-edit-data-loss, task 4.5, lock part).
@MainActor
final class SaveRaceTests: XCTestCase {

    private let orgId = "org-acme"
    private let orgKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xAC, count: 32),
        macKey:        Data(repeating: 0xCE, count: 32)
    )

    // MARK: - Tracer: a save that finishes after lock throws and leaves nothing

    func testStoreGeneration_isCurrentAndInvalidate_areSynchronous() async {
        let store = RawCipherStore()

        // No `await` on any of the token calls: the check and the write that follows it must be able
        // to share one actor turn.
        let token = store.currentGeneration()
        XCTAssertTrue(store.isCurrent(token))

        store.invalidate()
        XCTAssertFalse(store.isCurrent(token), "invalidate() makes every earlier token stale")
        let refused = await store.upsert(Self.record("a"), ifCurrent: token)
        XCTAssertFalse(refused, "A write with a stale token is refused")
        let countAfterRefusal = await store.count
        XCTAssertEqual(countAfterRefusal, 0)

        let fresh = store.currentGeneration()
        XCTAssertNotEqual(fresh, token)
        XCTAssertTrue(store.isCurrent(fresh))

        await store.clear()
        XCTAssertFalse(store.isCurrent(fresh), "clear() also makes earlier tokens stale")
    }

    func testUpdateFinishingAfterLock_throwsAndLeavesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1", name: "Original")
        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        await rig.cache(item)
        let vault = rig.vault
        rig.api.whileUpdatingCipher = { await vault.clearVault() }

        await assertThrowsVaultLocked { _ = try await rig.vault.update(StaleWriteRig.renamed(item)) }

        XCTAssertEqual(rig.api.updateCipherCallCount, 1)
        await assertNothingLeft(in: rig, id: "c1")
    }

    func testCreateFinishingAfterLock_throwsAndLeavesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let vault = rig.vault
        rig.api.whileCreatingCipher = { await vault.clearVault() }

        await assertThrowsVaultLocked { _ = try await rig.vault.create(DraftVaultItem(StaleWriteRig.login("n1", name: "New"))) }

        XCTAssertEqual(rig.api.createCipherCallCount, 1)
        await assertNothingLeft(in: rig, id: "n1")
    }

    func testOrgUpdateLockDuringCollections_throwsAndLeavesNothing() async throws {
        let (rig, item) = try await orgRig()
        let vault = rig.vault
        rig.api.whileUpdatingCollections = { await vault.clearVault() }

        await assertThrowsVaultLocked {
            var draft = StaleWriteRig.renamed(item)
            draft.collectionIds = ["col-a"]
            _ = try await rig.vault.update(draft)
        }

        XCTAssertEqual(rig.api.updateCipherCallCount, 1)
        XCTAssertEqual(rig.api.updateCipherCollectionsCallCount, 1, "The lock lands during the collections request")
        await assertNothingLeft(in: rig, id: item.id)
    }

    func testOldSaveAfterLockAndUnlock_doesNotTouchTheNewSession() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1", name: "Original")
        try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        await rig.cache(item)
        let vault = rig.vault
        let store = rig.store
        // The next session: the same id, another name, a record of its own. The record is built
        // here, where a seeding failure fails the test at its cause; the hook below cannot throw.
        let nextItem = StaleWriteRig.login("c1", name: "Next session")
        let scratch = RawCipherStore()
        try await RepositoryFixtures.seedRecords(for: [nextItem], in: scratch, vaultKeys: StaleWriteRig.vaultKeys)
        let seeded = await scratch.record(for: "c1")
        let nextRecord = try XCTUnwrap(seeded)
        rig.api.whileUpdatingCipher = {
            await vault.clearVault()
            await vault.populate(items: [nextItem], folders: [], organizations: [], collections: [], syncedAt: Date())
            await store.upsert(nextRecord, ifCurrent: store.currentGeneration())
        }

        await assertThrowsVaultLocked { _ = try await rig.vault.update(StaleWriteRig.renamed(item)) }

        let names = try await rig.vault.allItems().map(\.name)
        XCTAssertEqual(names, ["Next session"], "The old save must not replace the new session's item")
        let storedRecord = await rig.store.record(for: "c1")
        let stored = try XCTUnwrap(storedRecord)
        let storedName = try CipherMapper().map(raw: stored, vaultKeys: StaleWriteRig.vaultKeys, orgKeys: [:]).item.name
        XCTAssertEqual(storedName, "Next session", "The old save must not replace the new session's record")
    }

    // MARK: - A sync result that arrives after lock

    func testPopulateWithAStaleSession_changesNothing() async throws {
        let rig = await StaleWriteRig.make()
        let session = rig.store.currentGeneration()
        let item = StaleWriteRig.login("c1", name: "Synced")

        await rig.vault.populate(items: [item], folders: [], organizations: [], collections: [],
                                 syncedAt: Date(), session: session)
        let listed = try await rig.vault.allItems().map(\.name)
        XCTAssertEqual(listed, ["Synced"], "A populate with the current session goes through")

        await rig.vault.clearVault()
        let countsAfterLock = try await rig.vault.itemCounts()
        await rig.vault.populate(items: [item], folders: [], organizations: [], collections: [],
                                 syncedAt: Date(), session: session)

        let afterStale = try await rig.vault.allItems()
        XCTAssertTrue(afterStale.isEmpty, "A sync result that arrives after lock must not refill the vault")
        let countsAfterStale = try await rig.vault.itemCounts()
        XCTAssertEqual(countsAfterStale, countsAfterLock, "The indexes stay as the lock left them")
    }

    /// The debug-only test seam populates under the session that is current when it is called.
    func testPopulateWithoutSession_stillPopulates() async throws {
        let rig = await StaleWriteRig.make()
        await rig.vault.populate(items: [StaleWriteRig.login("c1", name: "Seam")], folders: [],
                                 organizations: [], collections: [], syncedAt: Date())

        let listed = try await rig.vault.allItems().map(\.name)
        XCTAssertEqual(listed, ["Seam"], "The UI-test seam and the tests populate the current session")
    }

    /// A token can only be current if the store handed it out: one built anywhere else is refused
    /// like a token from before a lock.
    func testTokenBuiltOutsideTheStore_isNeverCurrent() async throws {
        let rig = await StaleWriteRig.make()
        let forged = VaultSessionToken()

        XCTAssertFalse(rig.store.isCurrent(forged), "A token the store did not hand out is never current")
        XCTAssertNotEqual(forged, rig.store.currentGeneration())
        await rig.vault.populate(items: [StaleWriteRig.login("c1", name: "Forged")], folders: [],
                                 organizations: [], collections: [], syncedAt: Date(), session: forged)

        let listed = try await rig.vault.allItems()
        XCTAssertTrue(listed.isEmpty, "A populate with a token from outside the store changes nothing")
    }

    func testSyncPassesItsSessionToPopulate() async throws {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: StaleWriteRig.vaultKeys)
        crypto.stubbedDecryptList = []
        let mockVault = MockVaultRepository()
        let store = RawCipherStore()
        let sync = await RepositoryFixtures.syncRepository(
            apiClient: api, crypto: crypto, vaultRepository: mockVault, vaultKeyCache: VaultKeyCache(),
            recordStore: store)
        let before = store.currentGeneration()

        _ = try await sync.sync(progress: { _ in })

        XCTAssertEqual(mockVault.lastPopulateSession, before,
                       "The sync hands populate the generation it read at its start")
    }

    // MARK: - Writes to one item run one after another

    func testTwoUpdatesOfOneItem_runOneAfterAnother() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1", name: "Original")
        try await seed([item], in: rig)
        // The server's answer carries a newer revision, as a real save does.
        rig.api.updateCipherResponse = try await Self.storedRecord("c1", in: rig.store, revision: Self.laterRevision)
        let gate = SaveGate()
        rig.api.whileUpdatingCipher = { await gate.hold() }
        let vault = rig.vault

        let first = Task { try await vault.update(StaleWriteRig.renamed(item)) }
        let firstInFlight = await gate.waitUntilEntered(1)
        XCTAssertTrue(firstInFlight, "The first PUT is in flight")
        // Same old draft revision: the second edit was made on the copy the first one is replacing.
        let second = Task { try await vault.update(StaleWriteRig.renamed(item)) }
        await settle()
        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The second update waits for the first")

        await gate.open()
        _ = try await first.value
        do {
            _ = try await second.value
            XCTFail("The queued save runs against the record the first one stored, so it conflicts")
        } catch VaultError.conflict {
            // expected: the pre-check ran against the newer stored revision
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The conflict is found without a request")
    }

    func testUpdatesOfTwoItems_runInParallel() async throws {
        let rig = await StaleWriteRig.make()
        let items = [StaleWriteRig.login("c1"), StaleWriteRig.login("c2")]
        try await seed(items, in: rig)
        let gate = SaveGate()
        rig.api.whileUpdatingCipher = { await gate.hold() }
        let vault = rig.vault

        let first = Task { try await vault.update(StaleWriteRig.renamed(items[0])) }
        let second = Task { try await vault.update(StaleWriteRig.renamed(items[1])) }

        let bothInFlight = await gate.waitUntilEntered(2)
        XCTAssertTrue(bothInFlight, "Writes to different items do not wait for each other")
        await gate.open()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(rig.api.updateCipherCallCount, 2)
    }

    func testWriteQueuedBeforeLock_sendsNothing() async throws {
        let rig = await StaleWriteRig.make()
        let item = StaleWriteRig.login("c1", name: "Original")
        try await seed([item], in: rig)
        let gate = SaveGate()
        rig.api.whileUpdatingCipher = { await gate.hold() }
        let vault = rig.vault

        let first = Task { try await vault.update(StaleWriteRig.renamed(item)) }
        let firstInFlight = await gate.waitUntilEntered(1)
        XCTAssertTrue(firstInFlight)
        let second = Task { try await vault.update(StaleWriteRig.renamed(item)) }
        await settle()
        await vault.clearVault()
        await gate.open()

        for save in [first, second] {
            do {
                _ = try await save.value
                XCTFail("A save started before the lock must throw after it")
            } catch VaultError.vaultLocked {
                // expected
            }
        }
        XCTAssertEqual(rig.api.updateCipherCallCount, 1, "The queued update sends nothing after the lock")
        await assertNothingLeft(in: rig, id: "c1")
    }

    func testQueue_isEmptyAfterwards() async throws {
        let rig = await StaleWriteRig.make()
        let items = [StaleWriteRig.login("c1"), StaleWriteRig.login("c2")]
        try await seed(items, in: rig)
        let gate = SaveGate()
        rig.api.whileUpdatingCipher = { await gate.hold() }
        let vault = rig.vault

        let saves = [
            Task { try await vault.update(StaleWriteRig.renamed(items[0])) },
            Task { try await vault.update(StaleWriteRig.renamed(items[0])) },
            Task { try await vault.update(StaleWriteRig.renamed(items[1])) },
        ]
        let held = await gate.waitUntilEntered(2)
        XCTAssertTrue(held)
        let whileHeld = await vault.queuedWriteCount
        XCTAssertEqual(whileHeld, 2, "One entry per item with a write in the queue")

        await gate.open()
        _ = try await saves[0].value
        do {
            _ = try await saves[1].value
            XCTFail("The second save of c1 is refused")
        } catch VaultError.itemRevisionUnavailable {
            // The mock answers the first save with a bare echo of the request, which carries no
            // revision, so the record that save stored has none and the queued one finds no revision
            // to check against. A failed write must not keep the queue busy; any other error fails.
        }
        _ = try await saves[2].value

        let afterwards = await vault.queuedWriteCount
        XCTAssertEqual(afterwards, 0, "The queue keeps nothing once its writes have finished")
    }

    // MARK: - Helpers

    private static let laterRevision = RepositoryFixtures.serverRevisionString(
        for: RepositoryFixtures.revisionDate.addingTimeInterval(60))

    /// Stores and caches `items` as a sync would leave them.
    private func seed(_ items: [VaultItem], in rig: StaleWriteRig) async throws {
        for item in items {
            try await rig.storeRecord(of: item, revision: RepositoryFixtures.serverRevisionString(for: item.revisionDate))
        }
        await rig.vault.populate(items: items, folders: [Folder(id: "work", name: "Work")],
                                 organizations: [], collections: [], syncedAt: Date())
    }

    /// The stored record of `id` with another `revisionDate`, for stubbing a server answer.
    private static func storedRecord(_ id: String, in store: RawCipherStore, revision: String) async throws -> RawCipher {
        let stored = await store.record(for: id)
        let data = try JSONEncoder().encode(try XCTUnwrap(stored))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["revisionDate"] = revision
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Lets queued work run: there is no event to wait for when the thing under test is "nothing
    /// happens while the first write is held".
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static func record(_ id: String) -> RawCipher {
        RawCipher(
            id: id, organizationId: nil, folderId: nil, type: 1, name: "2.x|y|z", notes: nil,
            favorite: false, reprompt: nil, deletedDate: nil, creationDate: nil,
            revisionDate: nil, login: nil, card: nil, identity: nil, secureNote: nil,
            sshKey: nil, fields: nil, key: nil, attachments: nil
        )
    }

    /// A rig with one organization item cached and stored, and the organization key available.
    private func orgRig() async throws -> (StaleWriteRig, VaultItem) {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: StaleWriteRig.vaultKeys)
        crypto.stubbedVaultKeys = StaleWriteRig.vaultKeys
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: [orgId: orgKeys])
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, recordStore: store)
        let item = VaultItem(
            id: "o1", name: "Shared", isFavorite: false, isDeleted: false, creationDate: Date(),
            revisionDate: RepositoryFixtures.revisionDate,
            content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])),
            organizationId: orgId)
        try await RepositoryFixtures.seedRecords(
            for: [item], in: store, vaultKeys: StaleWriteRig.vaultKeys, orgKeys: [orgId: orgKeys])
        await vault.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
        return (StaleWriteRig(api: api, store: store, vault: vault), item)
    }

    private func assertThrowsVaultLocked(
        _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("The save must throw after a lock", file: file, line: line)
        } catch VaultError.vaultLocked {
            // expected: the save throws, so no success callback can run for it
        } catch {
            XCTFail("Expected vaultLocked, got \(error)", file: file, line: line)
        }
    }

    /// After a lock nothing of the save is left: no record, no cached item, no way to look it up.
    private func assertNothingLeft(
        in rig: StaleWriteRig, id: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let storedCount = await rig.store.count
        XCTAssertEqual(storedCount, 0, "The record store stays empty", file: file, line: line)
        let cached = try? await rig.vault.allItems()
        XCTAssertEqual(cached?.isEmpty, true, "No item is cached", file: file, line: line)
        do {
            _ = try await rig.vault.itemDetail(id: id)
            XCTFail("The item must not be found", file: file, line: line)
        } catch VaultError.itemNotFound {
            // expected
        } catch {
            XCTFail("Expected itemNotFound, got \(error)", file: file, line: line)
        }
    }
}

/// Holds a mocked request until `open()`, so a test can start more work while it is in flight.
private actor SaveGate {
    private var entered = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    /// True once `count` requests are being held; gives up after about two seconds so a broken
    /// queue fails the test instead of hanging it.
    func waitUntilEntered(_ count: Int) async -> Bool {
        for _ in 0..<400 {
            if entered >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return entered >= count
    }
}
