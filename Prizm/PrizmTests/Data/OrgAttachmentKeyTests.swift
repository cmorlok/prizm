import XCTest
@testable import Prizm

/// Attachments on organization items use the organization key, every item has a recorded key
/// source, and attachments that earlier versions wrapped with the personal key are found and
/// still open (openspec change fix-org-attachment-key, tasks 1.2, 1.3, 3.1, 3.2, 4.1, 4.2).
///
/// Real crypto on purpose (Constitution VII): a mock key would not notice the wrong key.
@MainActor
final class OrgAttachmentKeyTests: XCTestCase {

    private let mapper = CipherMapper()

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - Sync rig (golden account: real profile, org key and RSA unwrap)

    private struct SyncRig {
        let sync: SyncRepositoryImpl
        let keyCache: VaultKeyCache
        let keyService: VaultKeyServiceImpl
    }

    private func makeSyncRig(golden: GoldenVault.Snapshot, ciphers: [RawCipher]) async throws -> SyncRig {
        let client = PrizmAPIClientImpl(session: StubURLProtocol.makeSession())
        await client.setBaseURL(URL(string: "https://vault.example.com")!)
        await client.setAccessToken("token")
        let crypto = PrizmCryptoServiceImpl()
        await crypto.unlockWith(keys: golden.vaultKeys)
        let profileIds = await RepositoryFixtures.profileIds(seededWith: nil)
        let orgKeyCache = OrgKeyCache()
        let keyCache = VaultKeyCache()
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: client, crypto: crypto, orgKeyCache: orgKeyCache, profileIds: profileIds,
            recordStore: store, vaultKeyCache: keyCache
        )
        let sync = await RepositoryFixtures.syncRepository(
            apiClient: client, crypto: crypto, vaultRepository: vault,
            vaultKeyCache: keyCache, orgKeyCache: orgKeyCache, profileIds: profileIds, recordStore: store
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden.rawJSON) as? [String: Any])
        object["ciphers"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ciphers))
        let body = try JSONSerialization.data(withJSONObject: object)
        StubURLProtocol.responder = { _ in .status(200, body: body) }
        let service = VaultKeyServiceImpl(cache: keyCache, orgKeyCache: orgKeyCache, crypto: crypto)
        return SyncRig(sync: sync, keyCache: keyCache, keyService: service)
    }

    // MARK: - 3.1 Every item has a source after sync

    func testSync_recordsASourceForEveryItem() async throws {
        let golden = try await GoldenVault.load()
        let orgKeys = try XCTUnwrap(golden.orgKeys[GoldenVault.orgId])
        let personalItemKey = KeyedCipherBuilder.randomKeys()
        let orgItemKey = KeyedCipherBuilder.randomKeys()
        let ciphers = [
            KeyedCipherBuilder.login(id: "p-keyless", name: "P", activeKeys: golden.vaultKeys),
            KeyedCipherBuilder.login(id: "p-keyed", name: "PK", activeKeys: golden.vaultKeys, itemKey: personalItemKey),
            KeyedCipherBuilder.login(id: "o-keyless", name: "O", organizationId: GoldenVault.orgId,
                                     activeKeys: orgKeys),
            KeyedCipherBuilder.login(id: "o-keyed", name: "OK", organizationId: GoldenVault.orgId,
                                     activeKeys: orgKeys, itemKey: orgItemKey),
        ]
        let rig = try await makeSyncRig(golden: golden, ciphers: ciphers)

        _ = try await rig.sync.sync(progress: { _ in })

        let pKeyless = await rig.keyCache.source(for: "p-keyless")
        let pKeyed = await rig.keyCache.source(for: "p-keyed")
        let oKeyless = await rig.keyCache.source(for: "o-keyless")
        let oKeyed = await rig.keyCache.source(for: "o-keyed")
        XCTAssertEqual(pKeyless, .personal)
        XCTAssertEqual(pKeyed, .itemKey(personalItemKey.toData()))
        XCTAssertEqual(oKeyless, .organization(orgId: GoldenVault.orgId))
        XCTAssertEqual(oKeyed, .itemKey(orgItemKey.toData()))
    }

    // MARK: - 1.2 Upload to a synced org item without its own key

    func testUploadToSyncedKeylessOrgItem_wrapsTheAttachmentKeyWithTheOrgKey() async throws {
        let golden = try await GoldenVault.load()
        let orgKeys = try XCTUnwrap(golden.orgKeys[GoldenVault.orgId])
        let rig = try await makeSyncRig(golden: golden, ciphers: [
            KeyedCipherBuilder.login(id: "o-keyless", name: "O", organizationId: GoldenVault.orgId, activeKeys: orgKeys)
        ])
        _ = try await rig.sync.sync(progress: { _ in })
        let api = MockPrizmAPIClient()
        let upload = UploadAttachmentUseCaseImpl(
            repository: AttachmentRepositoryImpl(apiClient: api, crypto: PrizmCryptoServiceImpl(),
                                                 vaultRepository: MockVaultRepository()),
            vaultKeyService: rig.keyService)

        _ = try await upload.execute(cipherId: "o-keyless", fileName: "plan.pdf", data: Data("x".utf8))

        try assertWrapped(api.lastAttachmentMetadataRequest, with: orgKeys, not: golden.vaultKeys)
    }

    // MARK: - 1.3 / 3.2 Create records the source

    private func makeCreateRig() async -> (vault: VaultRepositoryImpl, api: MockPrizmAPIClient,
                                           cache: VaultKeyCache, service: VaultKeyServiceImpl,
                                           vaultKeys: CryptoKeys, orgKeys: CryptoKeys) {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let api = MockPrizmAPIClient()
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys
        crypto._isUnlocked = true
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        let cache = VaultKeyCache()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, vaultKeyCache: cache)
        let service = VaultKeyServiceImpl(cache: cache, orgKeyCache: orgKeyCache, crypto: crypto)
        return (vault, api, cache, service, vaultKeys, orgKeys)
    }

    func testCreateOrgItem_recordsTheOrganization_andItsKeyIsTheOrgKey() async throws {
        let rig = await makeCreateRig()
        rig.api.createOrgCipherResponse = KeyedCipherBuilder.login(
            id: "new-org", name: "New shared", organizationId: "org-1", collectionIds: ["col-a"],
            activeKeys: rig.orgKeys)
        var draft = DraftVaultItem.blank(type: .login)
        draft.name = "New shared"
        draft.organizationId = "org-1"
        draft.collectionIds = ["col-a"]

        _ = try await rig.vault.create(draft)

        let source = await rig.cache.source(for: "new-org")
        XCTAssertEqual(source, .organization(orgId: "org-1"))
        let key = try await rig.service.cipherKey(for: "new-org")
        XCTAssertEqual(key, rig.orgKeys.toData(), "An attachment before the next sync uses the org key")
    }

    func testCreateFinishingAfterALock_recordsNoKeySource() async throws {
        let rig = await makeCreateRig()
        rig.api.createCipherResponse = KeyedCipherBuilder.login(id: "new-late", name: "Late", activeKeys: rig.vaultKeys)
        let cache = rig.cache
        // The lock clears the key cache while the create request is on its way.
        rig.api.whileCreatingCipher = { await cache.clear() }
        var draft = DraftVaultItem.blank(type: .login)
        draft.name = "Late"

        _ = try? await rig.vault.create(draft)

        let source = await rig.cache.source(for: "new-late")
        XCTAssertNil(source, "A source recorded after the lock would outlive the session")
    }

    func testCreatePersonalItem_recordsPersonal() async throws {
        let rig = await makeCreateRig()
        rig.api.createCipherResponse = KeyedCipherBuilder.login(id: "new-mine", name: "Mine", activeKeys: rig.vaultKeys)
        var draft = DraftVaultItem.blank(type: .login)
        draft.name = "Mine"

        _ = try await rig.vault.create(draft)

        let source = await rig.cache.source(for: "new-mine")
        XCTAssertEqual(source, .personal)
    }

    // MARK: - 4.1 Attachments wrapped with the personal key

    /// `raw` with one attachment whose file name and key are encrypted with `keys`.
    private func withAttachment(_ raw: RawCipher, wrappedWith keys: CryptoKeys) throws -> RawCipher {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: Any])
        json["attachments"] = [[
            "id": "att-1",
            "fileName": KeyedCipherBuilder.encrypt("plan.pdf", keys: keys),
            "key": try EncString.encrypt(data: KeyedCipherBuilder.randomKeys().toData(), keys: keys).toString(),
            "size": "3",
            "sizeName": "3 B",
        ]]
        return try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testKeylessOrgItem_attachmentUnderTheVaultKey_isKeptAndFlagged() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let raw = try withAttachment(
            KeyedCipherBuilder.login(id: "o", name: "O", organizationId: "org-1", activeKeys: orgKeys),
            wrappedWith: vaultKeys)

        let item = try mapper.map(raw: raw, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys]).item

        XCTAssertEqual(item.attachments.map(\.fileName), ["plan.pdf"])
        XCTAssertEqual(item.attachments.first?.wrappedWithPersonalKey, true)
    }

    func testKeylessOrgItem_attachmentUnderTheOrgKey_isNotFlagged() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let raw = try withAttachment(
            KeyedCipherBuilder.login(id: "o", name: "O", organizationId: "org-1", activeKeys: orgKeys),
            wrappedWith: orgKeys)

        let item = try mapper.map(raw: raw, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys]).item

        XCTAssertEqual(item.attachments.first?.wrappedWithPersonalKey, false)
    }

    func testKeylessOrgItem_attachmentUnderNeitherKey_isDropped() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let raw = try withAttachment(
            KeyedCipherBuilder.login(id: "o", name: "O", organizationId: "org-1", activeKeys: orgKeys),
            wrappedWith: KeyedCipherBuilder.randomKeys())

        let item = try mapper.map(raw: raw, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys]).item

        XCTAssertTrue(item.attachments.isEmpty)
    }

    func testKeyedOrgItem_getsNoSecondAttempt() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let raw = try withAttachment(
            KeyedCipherBuilder.login(id: "o", name: "O", organizationId: "org-1", activeKeys: orgKeys,
                                     itemKey: KeyedCipherBuilder.randomKeys()),
            wrappedWith: vaultKeys)

        let item = try mapper.map(raw: raw, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys]).item

        XCTAssertTrue(item.attachments.isEmpty, "Prizm always used the item key for keyed items")
    }

    func testPersonalItem_attachmentIsNotFlagged() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let raw = try withAttachment(KeyedCipherBuilder.login(id: "p", name: "P", activeKeys: vaultKeys),
                                     wrappedWith: vaultKeys)

        let item = try mapper.map(raw: raw, vaultKeys: vaultKeys).item

        XCTAssertEqual(item.attachments.first?.wrappedWithPersonalKey, false)
    }

    // MARK: - 4.2 A flagged attachment opens with the personal key

    func testDownloadOfAFlaggedAttachment_unwrapsItsKeyWithTheVaultKey() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let crypto = PrizmCryptoServiceImpl()
        await crypto.unlockWith(keys: vaultKeys)
        let plain = Data("only mine".utf8)
        var attachmentKey = try crypto.generateAttachmentKey()
        defer { attachmentKey.resetBytes(in: attachmentKey.indices) }
        let api = MockPrizmAPIClient()
        api.downloadBlobResult = try crypto.encryptData(plain, attachmentKey: attachmentKey)
        let cache = VaultKeyCache()
        await cache.populate(sources: ["o": .organization(orgId: "org-1")])
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        let download = DownloadAttachmentUseCaseImpl(
            repository: AttachmentRepositoryImpl(apiClient: api, crypto: crypto, vaultRepository: MockVaultRepository()),
            vaultKeyService: VaultKeyServiceImpl(cache: cache, orgKeyCache: orgKeyCache, crypto: crypto))
        let flagged = Attachment(
            id: "att-1", fileName: "plan.pdf",
            encryptedKey: try crypto.encryptAttachmentKey(attachmentKey, cipherKey: vaultKeys),
            size: plain.count, sizeName: "9 B", url: nil, wrappedWithPersonalKey: true)

        let opened = try await download.execute(cipherId: "o", attachment: flagged)

        XCTAssertEqual(opened, plain)
    }

    // MARK: - Helpers

    private func assertWrapped(
        _ request: AttachmentMetadataRequest?, with keys: CryptoKeys, not other: CryptoKeys,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let sent = try XCTUnwrap(request, "No attachment was created", file: file, line: line)
        let key = try EncString(string: sent.key)
        XCTAssertNoThrow(try key.decrypt(keys: keys), "The attachment key opens with the org key", file: file, line: line)
        XCTAssertThrowsError(try key.decrypt(keys: other), "and not with the vault key", file: file, line: line)
        let name = try EncString(string: sent.fileName)
        XCTAssertEqual(String(data: try name.decrypt(keys: keys), encoding: .utf8), "plan.pdf", file: file, line: line)
    }
}
