import XCTest
@testable import Prizm

/// What `VaultRepositoryImpl.update()` does with the revision of the stored server record: refuses
/// an edit when it has no readable revision, compares it with the draft's, and leaves Prizm's own
/// operations alone (openspec change fix-cipher-edit-data-loss, tasks 4.1 to 4.3).
@MainActor
final class StaleWriteWireTests: XCTestCase {

    private let vaultKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xDE, count: 32),
        macKey:        Data(repeating: 0xAD, count: 32)
    )

    // MARK: - Helpers

    private struct Rig {
        let api: MockPrizmAPIClient
        let store: RawCipherStore
        let vault: VaultRepositoryImpl
    }

    /// An unlocked vault repository over a fresh record store; the profile id is seeded, so a save
    /// gets past `encryptedFor`.
    private func makeRig() async -> Rig {
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(apiClient: api, crypto: crypto, recordStore: store)
        return Rig(api: api, store: store, vault: vault)
    }

    private func login(_ id: String, name: String = "Login", revisionDate: Date = RepositoryFixtures.revisionDate) -> VaultItem {
        VaultItem(id: id, name: name, isFavorite: false, isDeleted: false, creationDate: Date(),
                  revisionDate: revisionDate,
                  content: .login(LoginContent(username: "u", password: "p", uris: [], totp: nil, notes: nil, customFields: [])))
    }

    /// The stored record of `item` with `revision` as its `revisionDate` (nil removes the key), as a
    /// sync of a server that sent that string would leave it.
    private func store(_ item: VaultItem, in rig: Rig, revision: String?) async throws {
        try await RepositoryFixtures.seedRecords(for: [item], in: rig.store, vaultKeys: vaultKeys)
        let seededRecord = await rig.store.record(for: item.id)
        let seeded = try XCTUnwrap(seededRecord)
        let data = try JSONEncoder().encode(seeded)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let revision { json["revisionDate"] = revision } else { json.removeValue(forKey: "revisionDate") }
        let replaced = try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
        let token = await rig.store.currentGeneration()
        await rig.store.upsert(replaced, ifCurrent: token)
    }

    /// A draft of `item` with another name, so it takes the full PUT path and not /partial.
    private func renamed(_ item: VaultItem, revisionDate: Date? = nil) -> DraftVaultItem {
        var draft = DraftVaultItem(item)
        draft.name = "Renamed"
        guard let revisionDate else { return draft }
        return DraftVaultItem(
            id: draft.id, folderId: draft.folderId, name: draft.name, isFavorite: draft.isFavorite,
            isDeleted: draft.isDeleted, creationDate: draft.creationDate, revisionDate: revisionDate,
            content: draft.content, reprompt: draft.reprompt,
            organizationId: draft.organizationId, collectionIds: draft.collectionIds)
    }

    // MARK: - Tracer: a readable stored revision is required, in any server shape

    func testUpdate_storedRevisionInEachServerShape_reachesThePut() async throws {
        let shapes: [(stored: String, draft: Date)] = [
            ("2026-10-26T10:00:00.123456Z", RepositoryFixtures.revisionDate),
            ("2026-10-26T10:00:00.1230000Z", RepositoryFixtures.revisionDate),
            ("2026-10-26T10:00:00Z", Date(timeIntervalSince1970: 1_793_008_800)),
        ]
        for shape in shapes {
            let rig = await makeRig()
            let item = login("c1", revisionDate: shape.draft)
            try await store(item, in: rig, revision: shape.stored)

            _ = try await rig.vault.update(renamed(item))

            XCTAssertEqual(rig.api.updateCipherCallCount, 1, "revision \(shape.stored) reaches the PUT")
        }
    }

    func testUpdate_missingEmptyUnparsableOrEpochRevision_throwsAndSendsNothing() async throws {
        let revisions: [String?] = [nil, "", "not-a-date", "1970-01-01T00:00:00.000Z"]
        for revision in revisions {
            let rig = await makeRig()
            let item = login("c1")
            try await store(item, in: rig, revision: revision)

            do {
                _ = try await rig.vault.update(renamed(item))
                XCTFail("revision \(String(describing: revision)) must refuse the save")
            } catch VaultError.itemRevisionUnavailable {
                // expected
            }

            XCTAssertEqual(rig.api.updateCipherCallCount, 0, "nothing is sent for \(String(describing: revision))")
        }
    }

    func testFolderOnlyChange_withoutStoredRevision_stillUsesPartial() async throws {
        let rig = await makeRig()
        let item = login("c1")
        try await store(item, in: rig, revision: nil)
        await rig.vault.populate(items: [item], folders: [Folder(id: "work", name: "Work")],
                                 organizations: [], collections: [], syncedAt: Date())
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
}
