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

    // MARK: - Helpers

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
