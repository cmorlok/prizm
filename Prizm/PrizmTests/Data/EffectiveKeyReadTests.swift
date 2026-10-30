import XCTest
@testable import Prizm

/// Items that another Bitwarden client gave their own key are read with that key: name, notes,
/// custom fields, type content and attachments, as the Bitwarden SDK does. Real crypto throughout;
/// the golden fixture was written by the browser extension on Vaultwarden 1.37.4.
///
/// A keyed item whose key or fields do not decrypt is dropped and counted. It is never retried with
/// the vault or organization key: a fallback would make mixed-key items visible (rbw#364).
@MainActor
final class EffectiveKeyReadTests: XCTestCase {

    private let mapper = CipherMapper()

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

    private struct SyncRig {
        let sync: SyncRepositoryImpl
        let vault: VaultRepositoryImpl
    }

    /// Real client (answering `body` to the sync GET), real crypto service unlocked with the golden
    /// vault key, real repositories.
    private func makeSyncRig(golden: GoldenVault.Snapshot, body: Data) async -> SyncRig {
        let client = await makeClient()
        let crypto = PrizmCryptoServiceImpl()
        await crypto.unlockWith(keys: golden.vaultKeys)
        let profileIds = await RepositoryFixtures.profileIds(seededWith: nil)
        let orgKeyCache = OrgKeyCache()
        // One store for both, as in the app: the sync's session token must be the vault's.
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: client, crypto: crypto, orgKeyCache: orgKeyCache, profileIds: profileIds,
            recordStore: store
        )
        let sync = await RepositoryFixtures.syncRepository(
            apiClient: client, crypto: crypto, vaultRepository: vault,
            vaultKeyCache: VaultKeyCache(), orgKeyCache: orgKeyCache, profileIds: profileIds,
            recordStore: store
        )
        StubURLProtocol.responder = { _ in .status(200, body: body) }
        return SyncRig(sync: sync, vault: vault)
    }

    /// The golden sync body with its `ciphers` replaced by `ciphers`, so a synthetic cipher goes
    /// through the real profile, organization key and RSA unwrap of the fixture account.
    private func goldenBody(replacingCiphersWith ciphers: [RawCipher], golden: GoldenVault.Snapshot) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden.rawJSON) as? [String: Any])
        let encoded = try JSONEncoder().encode(ciphers)
        object["ciphers"] = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func login(_ item: VaultItem, file: StaticString = #filePath, line: UInt = #line) throws -> LoginContent {
        guard case .login(let content) = item.content else {
            XCTFail("\(item.name) is not a login", file: file, line: line)
            throw CocoaError(.coderInvalidValue)
        }
        return content
    }

    // MARK: - Tracer: a real sync of the extension-written fixture

    func testGoldenSync_listsKeyedItemsWithEveryFieldDecrypted() async throws {
        let golden = try await GoldenVault.load()
        let rig = await makeSyncRig(golden: golden, body: golden.rawJSON)

        let result = try await rig.sync.sync(progress: { _ in })
        // One fixture item was archived on the server, so it is listed in Archive only (archived-items).
        let items = try await rig.vault.allItems() + rig.vault.items(for: .archive)

        XCTAssertEqual(result.failedDecryptionCount, 0)
        XCTAssertEqual(Set(items.map(\.id)), Set(GoldenVault.allIds), "all six fixture items are listed")
        XCTAssertEqual(items.count, 6)
        let archiveList = try await rig.vault.items(for: .archive)
        XCTAssertEqual(archiveList.count, 1, "the golden vault has one archived item")

        // Keyed passkey login: every field, both websites, the attachment name.
        let passkey = try await rig.vault.itemDetail(id: GoldenVault.passkeyId)
        let passkeyLogin = try login(passkey)
        XCTAssertFalse(passkey.name.isEmpty)
        XCTAssertFalse(try XCTUnwrap(passkeyLogin.username).isEmpty)
        XCTAssertFalse(try XCTUnwrap(passkeyLogin.password).isEmpty)
        XCTAssertEqual(Set(passkeyLogin.uris.map(\.uri)), ["https://webauthn.io/", "https://example.com/login"])
        XCTAssertEqual(passkey.attachments.count, 1)
        XCTAssertFalse(try XCTUnwrap(passkey.attachments.first).fileName.isEmpty)

        // Keyed SSH item.
        let ssh = try await rig.vault.itemDetail(id: GoldenVault.sshId)
        guard case .sshKey(let sshContent) = ssh.content else { return XCTFail("SSH item is not an SSH key") }
        XCTAssertTrue(try XCTUnwrap(sshContent.privateKey).hasPrefix("-----BEGIN"))
        XCTAssertTrue(try XCTUnwrap(sshContent.publicKey).hasPrefix("ssh-"))
        XCTAssertTrue(try XCTUnwrap(sshContent.keyFingerprint).hasPrefix("SHA256:"))

        // Keyed organization login (org key unwrapped through the real RSA path).
        let org = try await rig.vault.itemDetail(id: GoldenVault.orgLoginId)
        XCTAssertEqual(org.organizationId, GoldenVault.orgId)
        XCTAssertEqual(try login(org).uris.map(\.uri), ["https://example.com/org"])

        // Keyed archived item.
        let archived = try await rig.vault.itemDetail(id: GoldenVault.archivedId)
        XCTAssertEqual(try login(archived).uris.map(\.uri), ["https://example.com/archived"])

        // Keyless control and twin keep working.
        let control = try await rig.vault.itemDetail(id: GoldenVault.controlId)
        XCTAssertEqual(control.name, "Fixture Control")
        XCTAssertEqual(try login(control).uris.map(\.uri), ["https://example.com/control"])
        let twin = try await rig.vault.itemDetail(id: GoldenVault.twinId)
        XCTAssertEqual(twin.name, "Fixture Twin")
        XCTAssertEqual(try login(twin).uris.map(\.uri), ["https://example.com/twin"])
    }

    // MARK: - Keyless items decrypt as before

    func testKeylessFixtureItems_decryptAsBefore() async throws {
        let golden = try await GoldenVault.load()

        for (id, name) in [(GoldenVault.controlId, "Fixture Control"), (GoldenVault.twinId, "Fixture Twin")] {
            let raw = golden.cipher(id: id)
            XCTAssertNil(raw.key)
            let mapped = try mapper.map(raw: raw, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys)
            XCTAssertEqual(mapped.item.name, name)
            XCTAssertEqual(mapped.cipherKey, golden.vaultKeys.toData(), "a keyless item's effective key is the vault key")
        }
    }

    func testKeylessOrgItem_decryptsWithTheOrgKey() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let raw = KeyedCipherBuilder.login(
            id: "org-keyless", name: "Shared", username: "team", password: "pw", website: "https://example.com/shared",
            organizationId: "org-1", collectionIds: ["col-a"], activeKeys: orgKeys
        )

        let mapped = try mapper.map(raw: raw, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys])

        XCTAssertEqual(mapped.item.name, "Shared")
        XCTAssertEqual(mapped.cipherKey, orgKeys.toData())
        // The vault key must not open an org item.
        XCTAssertThrowsError(try mapper.map(raw: raw, vaultKeys: vaultKeys, orgKeys: ["org-1": vaultKeys]))
    }

    func testKeylessPersonalAndOrgInOneSync_eachUseTheirKey() async throws {
        let golden = try await GoldenVault.load()
        let personal = KeyedCipherBuilder.login(
            id: "p-keyless", name: "Personal keyless", username: "me", activeKeys: golden.vaultKeys
        )
        let org = KeyedCipherBuilder.login(
            id: "o-keyless", name: "Org keyless", username: "team",
            organizationId: GoldenVault.orgId, collectionIds: [], activeKeys: try XCTUnwrap(golden.orgKeys[GoldenVault.orgId])
        )
        let body = try goldenBody(replacingCiphersWith: [personal, org], golden: golden)
        let rig = await makeSyncRig(golden: golden, body: body)

        let result = try await rig.sync.sync(progress: { _ in })
        let items = try await rig.vault.allItems()

        XCTAssertEqual(result.failedDecryptionCount, 0)
        XCTAssertEqual(Set(items.map(\.name)), ["Personal keyless", "Org keyless"])
        XCTAssertEqual(try login(try XCTUnwrap(items.first { $0.name == "Org keyless" })).username, "team")
        XCTAssertEqual(try login(try XCTUnwrap(items.first { $0.name == "Personal keyless" })).username, "me")
    }

    // MARK: - Keyed items that do not decrypt under their own key

    private func unlockedCrypto(_ keys: CryptoKeys) async -> PrizmCryptoServiceImpl {
        let crypto = PrizmCryptoServiceImpl()
        await crypto.unlockWith(keys: keys)
        return crypto
    }

    func testKeyedItemWithFieldsUnderTheActiveKey_isDroppedAndCounted() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let itemKey = KeyedCipherBuilder.randomKeys()
        let keylessFirst = KeyedCipherBuilder.login(id: "a-keyless", name: "Keyless", activeKeys: vaultKeys)
        let keyedGood = KeyedCipherBuilder.login(id: "b-keyed", name: "Keyed", username: "u", activeKeys: vaultKeys, itemKey: itemKey)
        // Its key unwraps fine, but its fields were written with the vault key: a mixed-key item.
        let mixed = KeyedCipherBuilder.login(
            id: "c-mixed", name: "Mixed", activeKeys: vaultKeys, itemKey: itemKey, fieldKeys: vaultKeys
        )
        let keyedLast = KeyedCipherBuilder.login(
            id: "d-keyed", name: "Keyed again", activeKeys: vaultKeys, itemKey: KeyedCipherBuilder.randomKeys()
        )
        let crypto = await unlockedCrypto(vaultKeys)

        let result = try await crypto.decryptList(ciphers: [keylessFirst, keyedGood, mixed, keyedLast])

        XCTAssertEqual(result.failedCount, 1, "the mixed-key item is counted, not retried under the vault key")
        XCTAssertEqual(result.items.map(\.id), ["a-keyless", "b-keyed", "d-keyed"], "the others keep their input order")
        XCTAssertEqual(try login(result.items[1]).username, "u", "a keyed item decrypts under its own key next to a keyless one")
        XCTAssertEqual(result.keySources["b-keyed"], .itemKey(itemKey.toData()))
    }

    func testKeyedItemWhoseKeyIsWrappedWithAnotherKey_isDroppedAndCounted() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let good1 = KeyedCipherBuilder.login(id: "a", name: "A", activeKeys: vaultKeys, itemKey: KeyedCipherBuilder.randomKeys())
        let wrongWrap = KeyedCipherBuilder.login(
            id: "b", name: "B", activeKeys: vaultKeys, itemKey: KeyedCipherBuilder.randomKeys(),
            wrappingKeys: KeyedCipherBuilder.randomKeys()
        )
        let good2 = KeyedCipherBuilder.login(id: "c", name: "C", activeKeys: vaultKeys)
        let crypto = await unlockedCrypto(vaultKeys)

        let result = try await crypto.decryptList(ciphers: [good1, wrongWrap, good2])

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.items.map(\.id), ["a", "c"])
    }

    func testKeyedItemWhoseKeyIsNot64Bytes_isDropped() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let itemKey = KeyedCipherBuilder.randomKeys()
        let short = KeyedCipherBuilder.login(
            id: "short", name: "Short", activeKeys: vaultKeys, itemKey: itemKey, fieldKeys: vaultKeys, wrappedKeyBytes: Data(repeating: 7, count: 32)
        )
        let long = KeyedCipherBuilder.login(
            id: "long", name: "Long", activeKeys: vaultKeys, itemKey: itemKey, fieldKeys: vaultKeys, wrappedKeyBytes: Data(repeating: 7, count: 96)
        )
        let keyless = KeyedCipherBuilder.login(id: "keyless", name: "Keyless", activeKeys: vaultKeys)
        let crypto = await unlockedCrypto(vaultKeys)

        let result = try await crypto.decryptList(ciphers: [short, keyless, long])

        XCTAssertEqual(result.failedCount, 2, "32 and 96 byte keys are dropped and counted, without a crash")
        XCTAssertEqual(result.items.map(\.id), ["keyless"])
    }

    func testItemKeyThatIsNotAType2EncString_isRefusedEvenUnderTheRightKey() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let itemKey = KeyedCipherBuilder.randomKeys()
        let typed = KeyedCipherBuilder.login(id: "k", name: "Keyed", activeKeys: vaultKeys, itemKey: itemKey)
        let type2 = try XCTUnwrap(typed.key)
        XCTAssertEqual(try mapper.effectiveKeys(for: typed, activeKeys: vaultKeys).toData(), itemKey.toData())

        // The same IV and ciphertext without the MAC part: nothing authenticates it, so it is never
        // decrypted, not even under the right key (fix-encstring-validation), nor accepted as an item key.
        let parts = type2.dropFirst(2).split(separator: "|")
        let type0 = "0.\(parts[0])|\(parts[1])"
        XCTAssertThrowsError(try EncString(string: type0).decrypt(keys: vaultKeys)) { error in
            XCTAssertEqual(error as? EncStringError, .unsupportedEncType)
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(typed)) as? [String: Any])
        json["key"] = type0
        let macLess = try JSONDecoder().decode(RawCipher.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertThrowsError(try mapper.effectiveKeys(for: macLess, activeKeys: vaultKeys)) { error in
            XCTAssertEqual(error as? CipherMapperError, .fieldDecryptionFailed("key"))
        }
    }

    func testKeyedOrgItemWithFieldsUnderTheOrgKey_isNotListed() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let itemKey = KeyedCipherBuilder.randomKeys()
        // The item key unwraps under the org key, but the fields were written with the org key.
        let underOrgKey = KeyedCipherBuilder.login(
            id: "org-mixed-1", name: "Org mixed", organizationId: "org-1", collectionIds: ["col-a"],
            activeKeys: orgKeys, itemKey: itemKey, fieldKeys: orgKeys
        )
        // Same, with the fields written with the personal vault key.
        let underVaultKey = KeyedCipherBuilder.login(
            id: "org-mixed-2", name: "Org mixed", organizationId: "org-1", collectionIds: ["col-a"],
            activeKeys: orgKeys, itemKey: itemKey, fieldKeys: vaultKeys
        )

        XCTAssertThrowsError(try mapper.map(raw: underOrgKey, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys]))
        XCTAssertThrowsError(try mapper.map(raw: underVaultKey, vaultKeys: vaultKeys, orgKeys: ["org-1": orgKeys]))
    }

    // MARK: - cipherKey and optional fields

    func testMap_cipherKeyIsTheEffectiveKey() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let itemKey = KeyedCipherBuilder.randomKeys()
        let keyed = KeyedCipherBuilder.login(id: "k", name: "Keyed", activeKeys: vaultKeys, itemKey: itemKey)
        let keyless = KeyedCipherBuilder.login(id: "l", name: "Keyless", activeKeys: vaultKeys)

        XCTAssertEqual(try mapper.map(raw: keyed, vaultKeys: vaultKeys).cipherKey, itemKey.toData())
        XCTAssertEqual(try mapper.map(raw: keyless, vaultKeys: vaultKeys).cipherKey, vaultKeys.toData())
    }

    func testKeylessItemWithoutOptionalFields_mapsAsBefore() throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let raw = KeyedCipherBuilder.login(id: "bare", name: "Bare", activeKeys: vaultKeys)

        let item = try mapper.map(raw: raw, vaultKeys: vaultKeys).item

        XCTAssertEqual(item.name, "Bare")
        let content = try login(item)
        XCTAssertNil(content.username)
        XCTAssertNil(content.password)
        XCTAssertNil(content.notes)
        XCTAssertTrue(content.uris.isEmpty)
        XCTAssertTrue(content.customFields.isEmpty)
        XCTAssertTrue(item.attachments.isEmpty)
    }
}
