import XCTest
@testable import Prizm

/// Creates and full updates carry `encryptedFor`, the user id from the last sync. Vaultwarden 1.37.4
/// rejects a cipher body without it with HTTP 422; the official server treats it as optional.
/// `encryptedByKeyId` is never sent.
@MainActor
final class EncryptedForTests: XCTestCase {

    private let syncedProfileId = "00000000-0000-4000-8000-0000000000e2"

    private let vaultKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0xDE, count: 32),
        macKey:        Data(repeating: 0xAD, count: 32)
    )

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

    private func unlockedCrypto() async -> MockPrizmCryptoService {
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        return crypto
    }

    private func loginDraft(id: String, name: String) -> DraftVaultItem {
        DraftVaultItem(
            id: id, name: name, isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .login(DraftLoginContent(LoginContent(
                username: nil, password: nil, uris: [], totp: nil, notes: nil, customFields: []
            ))),
            reprompt: 0
        )
    }

    /// The item a stored record is seeded for. A save is built over the server's stored record, so a
    /// test that saves "c1" or the org draft first stores one. Seed after a sync or `clearVault()`:
    /// both empty the store.
    private func storedItem(id: String, organizationId: String? = nil) -> VaultItem {
        VaultItem(
            id: id, name: "Original", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .login(LoginContent(username: nil, password: nil, uris: [], totp: nil, notes: nil, customFields: [])),
            organizationId: organizationId
        )
    }

    private func syncBody(profileId: String) -> Data {
        Data(#"{"profile":{"id":"\#(profileId)","email":"e@example.com","key":"2.k=="},"ciphers":[]}"#.utf8)
    }

    // MARK: - Tracer: sync, then a full update over the real client

    func testSyncThenFullUpdate_putBodyCarriesTheSyncedProfileId() async throws {
        let client = await makeClient()
        let crypto = await unlockedCrypto()
        let profileIds = await RepositoryFixtures.profileIds(seededWith: nil)
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: client, crypto: crypto, profileIds: profileIds, recordStore: store)
        let sync = await RepositoryFixtures.syncRepository(
            apiClient: client, crypto: crypto, vaultRepository: vault,
            vaultKeyCache: VaultKeyCache(), profileIds: profileIds, recordStore: store
        )
        let body = syncBody(profileId: syncedProfileId)
        StubURLProtocol.responder = { request in
            if request.httpMethod == "GET" { return .status(200, body: body) }
            // The echo decrypts with the same keys, so update() can map it.
            return .status(200, body: StubURLProtocol.requests.last?.body ?? Data())
        }

        _ = try await sync.sync(progress: { _ in })
        // The sync body has no ciphers and so emptied the store: seed the record the save is built on.
        try await RepositoryFixtures.seedRecords(for: [storedItem(id: "c1")], in: store, vaultKeys: vaultKeys)
        // No cached item for "c1", so the full PUT path runs (an unchanged item would use /partial).
        _ = try await vault.update(loginDraft(id: "c1", name: "Renamed"))

        let put = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(put.method, "PUT")
        XCTAssertEqual(put.url?.path, "/api/ciphers/c1")
        XCTAssertEqual(put.jsonBody?["encryptedFor"] as? String, syncedProfileId)
        XCTAssertNil(put.jsonBody?["encryptedByKeyId"])
    }

    // MARK: - Repository: creates carry the synced id

    private let orgKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0x33, count: 32),
        macKey:        Data(repeating: 0x44, count: 32)
    )

    private func orgDraft(id: String = "c-org") -> DraftVaultItem {
        var draft = loginDraft(id: id, name: "Shared")
        draft.organizationId = "org-1"
        draft.collectionIds = ["col-a"]
        return draft
    }

    private func assertProfileIdUnavailable(
        _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected VaultError.profileIdUnavailable", file: file, line: line)
        } catch VaultError.profileIdUnavailable {
            // expected
        } catch {
            XCTFail("Expected VaultError.profileIdUnavailable, got \(error)", file: file, line: line)
        }
    }

    func testCreatePersonal_sendsTheSyncedProfileId() async throws {
        let api = MockPrizmAPIClient()
        let vault = await RepositoryFixtures.vaultRepository(apiClient: api, crypto: await unlockedCrypto())

        _ = try await vault.create(loginDraft(id: "n1", name: "New"))

        XCTAssertEqual(api.lastCreatedCipher?.encryptedFor, RepositoryFixtures.profileId)
        XCTAssertEqual(api.createOrgCipherCallCount, 0)
    }

    func testCreateOrg_sendsTheSyncedProfileId() async throws {
        let api = MockPrizmAPIClient()
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: await unlockedCrypto(), orgKeyCache: orgKeyCache)

        _ = try await vault.create(orgDraft())

        XCTAssertEqual(api.lastCreatedOrgCipher?.encryptedFor, RepositoryFixtures.profileId)
        XCTAssertEqual(api.createCipherCallCount, 0)
    }

    // MARK: - Wire: where the field lands in each request body

    private func rawCipher(encryptedFor: String?, organizationId: String? = nil,
                           collectionIds: [String] = []) -> RawCipher {
        RawCipher(
            id: "c1", organizationId: organizationId, folderId: nil, type: 1, name: "2.x|y|z",
            notes: nil, favorite: false, reprompt: nil, deletedDate: nil, creationDate: nil,
            revisionDate: nil, login: nil, card: nil, identity: nil, secureNote: nil, sshKey: nil,
            fields: nil, key: nil, collectionIds: collectionIds, attachments: nil,
            encryptedFor: encryptedFor
        )
    }

    private let minimalCipherJSON = #"{"id":"c1","type":1,"name":"2.x","favorite":false}"#

    private func respond(_ json: String) {
        StubURLProtocol.responder = { _ in .status(200, body: Data(json.utf8)) }
    }

    func testWire_updateCipher_topLevelEncryptedFor_noEncryptedByKeyId() async throws {
        respond(minimalCipherJSON)
        let client = await makeClient()

        _ = try await client.updateCipher(id: "c1", cipher: rawCipher(encryptedFor: "user-1"))

        let body = try XCTUnwrap(StubURLProtocol.requests.last?.jsonBody)
        XCTAssertEqual(body["encryptedFor"] as? String, "user-1")
        XCTAssertNil(body["encryptedByKeyId"])
    }

    func testWire_createCipher_topLevelEncryptedFor_noEncryptedByKeyId() async throws {
        respond(minimalCipherJSON)
        let client = await makeClient()

        _ = try await client.createCipher(cipher: rawCipher(encryptedFor: "user-1"))

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.url?.path, "/api/ciphers")
        XCTAssertEqual(request.jsonBody?["encryptedFor"] as? String, "user-1")
        XCTAssertNil(request.jsonBody?["encryptedByKeyId"])
    }

    func testWire_createOrgCipher_encryptedForOnlyInsideCipher() async throws {
        respond(minimalCipherJSON)
        let client = await makeClient()

        _ = try await client.createOrgCipher(
            cipher: rawCipher(encryptedFor: "user-1", organizationId: "org-1", collectionIds: ["col-a"]))

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.url?.path, "/api/ciphers/create")
        let body = try XCTUnwrap(request.jsonBody)
        let cipher = try XCTUnwrap(body["cipher"] as? [String: Any])
        XCTAssertEqual(cipher["encryptedFor"] as? String, "user-1")
        XCTAssertNil(body["encryptedFor"], "Outside `cipher` the official server would ignore it")
        XCTAssertNil(cipher["encryptedByKeyId"])
        XCTAssertNil(body["encryptedByKeyId"])
    }

    func testWire_partialAndCollections_carryNeitherKey() async throws {
        respond(#"{"favorite":true}"#)
        let client = await makeClient()

        _ = try await client.updateCipherPartial(id: "c1", folderId: "f1", favorite: true)
        try await client.updateCipherCollections(id: "c1", collectionIds: ["col-a"])

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/ciphers/c1/partial", "/api/ciphers/c1/collections"])
        for request in requests {
            XCTAssertNil(request.jsonBody?["encryptedFor"], request.url?.path ?? "")
            XCTAssertNil(request.jsonBody?["encryptedByKeyId"], request.url?.path ?? "")
        }
    }

    // MARK: - No id: fail closed, send nothing

    func testFullUpdate_withoutProfileId_throwsAndSendsNothing() async throws {
        let api = MockPrizmAPIClient()
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: await unlockedCrypto(), orgKeyCache: orgKeyCache,
            profileIds: await RepositoryFixtures.profileIds(seededWith: nil), recordStore: store)
        try await RepositoryFixtures.seedRecords(
            for: [storedItem(id: "c1"), storedItem(id: "c-org", organizationId: "org-1")],
            in: store, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys])

        // No cached item for either id, so both take the full PUT path; the org one has its key.
        await assertProfileIdUnavailable { _ = try await vault.update(self.loginDraft(id: "c1", name: "Renamed")) }
        await assertProfileIdUnavailable { _ = try await vault.update(self.orgDraft()) }

        XCTAssertEqual(api.updateCipherCallCount, 0, "No PUT may be sent")
        XCTAssertEqual(api.updateCipherCollectionsCallCount, 0)
    }

    func testCreate_withoutProfileId_throwsAndSendsNothing() async throws {
        let api = MockPrizmAPIClient()
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: await unlockedCrypto(), orgKeyCache: orgKeyCache,
            profileIds: await RepositoryFixtures.profileIds(seededWith: nil))

        await assertProfileIdUnavailable { _ = try await vault.create(self.loginDraft(id: "n1", name: "New")) }
        await assertProfileIdUnavailable { _ = try await vault.create(self.orgDraft()) }

        XCTAssertEqual(api.createCipherCallCount, 0, "No POST may be sent")
        XCTAssertEqual(api.createOrgCipherCallCount, 0)
    }

    /// A folder or favorite change goes through /partial, which carries no cipher body and so
    /// needs no `encryptedFor`.
    func testFolderOnlyChange_withoutProfileId_stillSavesThroughPartial() async throws {
        let api = MockPrizmAPIClient()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: await unlockedCrypto(),
            profileIds: await RepositoryFixtures.profileIds(seededWith: nil))
        let cached = VaultItem(
            id: "c1", name: "Cached", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .login(LoginContent(username: nil, password: nil, uris: [], totp: nil, notes: nil, customFields: []))
        )
        await vault.populate(items: [cached], folders: [], organizations: [], collections: [], syncedAt: Date())
        var draft = DraftVaultItem(cached)
        draft.folderId = "f1"

        let updated = try await vault.update(draft)

        XCTAssertEqual(updated.folderId, "f1")
        XCTAssertEqual(api.partialUpdates.count, 1)
        XCTAssertEqual(api.updateCipherCallCount, 0)
    }

    func testMissingOrgKeyAndProfileId_throwsOrganizationKeyUnavailableFirst() async throws {
        let api = MockPrizmAPIClient()
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: await unlockedCrypto(),
            profileIds: await RepositoryFixtures.profileIds(seededWith: nil), recordStore: store)
        // The record exists, encrypted under the organization key, but the vault's key cache has no
        // organization key: the save must fail on that, not on the missing record.
        try await RepositoryFixtures.seedRecords(
            for: [storedItem(id: "c-org", organizationId: "org-1")],
            in: store, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys])

        do {
            _ = try await vault.update(orgDraft())
            XCTFail("Expected organizationKeyUnavailable")
        } catch VaultError.organizationKeyUnavailable {
            // expected: the key check comes before the id check
        } catch {
            XCTFail("Expected organizationKeyUnavailable, got \(error)")
        }
    }

    // MARK: - Lifecycle of the held id

    private func syncedPair(api: MockPrizmAPIClient, profileIds: ProfileIdCache, store: RawCipherStore)
        async -> (vault: VaultRepositoryImpl, sync: SyncRepositoryImpl) {
        let crypto = await unlockedCrypto()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, profileIds: profileIds, recordStore: store)
        let sync = await RepositoryFixtures.syncRepository(
            apiClient: api, crypto: crypto, vaultRepository: vault,
            vaultKeyCache: VaultKeyCache(), profileIds: profileIds, recordStore: store)
        return (vault, sync)
    }

    private func syncResponse(profileId: String) -> SyncResponse {
        SyncResponse(
            profile: RawProfile(id: profileId, email: "e@example.com", name: nil, key: "2.k==", privateKey: nil),
            ciphers: [], folders: []
        )
    }

    /// Lock and sign-out both end in `clearVault()`, so a save after either has no id.
    func testClearVault_dropsTheProfileId() async throws {
        let api = MockPrizmAPIClient()
        let profileIds = await RepositoryFixtures.profileIds(seededWith: nil)
        let store = RawCipherStore()
        let (vault, sync) = await syncedPair(api: api, profileIds: profileIds, store: store)
        _ = try await sync.sync(progress: { _ in })
        let heldAfterSync = await profileIds.current()
        XCTAssertEqual(heldAfterSync, "pid")

        await vault.clearVault()
        await vault.clearVault()  // idempotent

        let heldAfterClear = await profileIds.current()
        XCTAssertNil(heldAfterClear)
        // clearVault() emptied the store too; seed after it so the save fails on the missing id and
        // this test keeps testing the id's lifecycle, not the missing record.
        try await RepositoryFixtures.seedRecords(for: [storedItem(id: "c1")], in: store, vaultKeys: vaultKeys)
        await assertProfileIdUnavailable { _ = try await vault.update(self.loginDraft(id: "c1", name: "Renamed")) }
        XCTAssertEqual(api.updateCipherCallCount, 0)
    }

    func testEmptyProfileIdFromSync_isTreatedAsMissing() async throws {
        let api = MockPrizmAPIClient()
        api.syncResponse = syncResponse(profileId: "")
        // A stale id from an earlier sync must not survive a sync that reports none.
        let profileIds = await RepositoryFixtures.profileIds(seededWith: "stale-id")
        let store = RawCipherStore()
        let (vault, sync) = await syncedPair(api: api, profileIds: profileIds, store: store)

        _ = try await sync.sync(progress: { _ in })
        try await RepositoryFixtures.seedRecords(for: [storedItem(id: "c1")], in: store, vaultKeys: vaultKeys)

        await assertProfileIdUnavailable { _ = try await vault.update(self.loginDraft(id: "c1", name: "Renamed")) }
        XCTAssertEqual(api.updateCipherCallCount, 0)
    }

    func testSecondSyncWithAnotherId_nextSaveCarriesTheNewId() async throws {
        let api = MockPrizmAPIClient()
        let store = RawCipherStore()
        let (vault, sync) = await syncedPair(
            api: api, profileIds: await RepositoryFixtures.profileIds(seededWith: nil), store: store)
        api.syncResponse = syncResponse(profileId: "profile-A")
        _ = try await sync.sync(progress: { _ in })
        api.syncResponse = syncResponse(profileId: "profile-B")
        _ = try await sync.sync(progress: { _ in })
        try await RepositoryFixtures.seedRecords(for: [storedItem(id: "c1")], in: store, vaultKeys: vaultKeys)

        _ = try await vault.update(loginDraft(id: "c1", name: "Renamed"))

        XCTAssertEqual(api.lastUpdatedCipher?.encryptedFor, "profile-B")
    }

    // MARK: - Message

    func testProfileIdUnavailable_message() {
        XCTAssertEqual(
            VaultError.profileIdUnavailable.errorDescription,
            "Prizm couldn't confirm which account this item belongs to. Lock and unlock Prizm, then try again."
        )
    }
}
