import XCTest
@testable import Prizm

/// The five-case key matrix of a save, with real crypto: which key encrypts the fields and what
/// `key` the request carries, for a keyed or keyless item, personal or in an organization, and an
/// item whose own key cannot be unwrapped.
///
/// The rule under test: the request's `key` is the stored `key` string itself (absent for an item
/// without one), the fields are encrypted with the item's effective key, and a key that does not
/// unwrap fails the save before anything is sent, never falling back to the vault or organization key.
@MainActor
final class KeyMatrixTests: XCTestCase {

    private let mapper = CipherMapper()

    private var api: MockPrizmAPIClient!
    private var store: RawCipherStore!
    private var orgKeyCache: OrgKeyCache!
    private var sut: VaultRepositoryImpl!

    override func setUp() async throws {
        try await super.setUp()
        api = MockPrizmAPIClient()
        store = RawCipherStore()
        orgKeyCache = OrgKeyCache()
    }

    // MARK: - Helpers

    /// A repository whose crypto is unlocked with `vaultKeys`, whose org key cache holds `orgKeys`
    /// and whose record store holds `records`.
    private func makeRepository(vaultKeys: CryptoKeys, orgKeys: [String: CryptoKeys], records: [RawCipher]) async {
        let crypto = MockPrizmCryptoService()
        await crypto.unlockWith(keys: vaultKeys)
        crypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        await orgKeyCache.replaceAll(with: orgKeys)
        sut = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: crypto, orgKeyCache: orgKeyCache, recordStore: store)
        let token = await store.currentGeneration()
        await store.replaceAll(records, ifCurrent: token)
    }

    /// The draft of the record as the edit sheet would open it, with a new name.
    private func renamedDraft(of raw: RawCipher, vaultKeys: CryptoKeys, orgKeys: [String: CryptoKeys],
                              to name: String) throws -> DraftVaultItem {
        var draft = DraftVaultItem(try mapper.map(raw: raw, vaultKeys: vaultKeys, orgKeys: orgKeys).item)
        draft.name = name
        return draft
    }

    private func decryptedName(_ cipher: RawCipher, with keys: CryptoKeys) throws -> String {
        let data = try EncString(string: cipher.name).decrypt(keys: keys)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func assertNameReadable(_ cipher: RawCipher, with keys: CryptoKeys, as expected: String,
                                    notWith wrong: [CryptoKeys], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try decryptedName(cipher, with: keys), expected, file: file, line: line)
        for other in wrong {
            XCTAssertThrowsError(try decryptedName(cipher, with: other), "must not read under another key", file: file, line: line)
        }
    }

    // MARK: - Keyed personal (fixture passkey login)

    func testKeyedPersonal_fixturePasskeyLogin() async throws {
        let golden = try await GoldenVault.load()
        let stored = golden.cipher(id: GoldenVault.passkeyId)
        await makeRepository(vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys, records: [stored])
        let draft = try renamedDraft(of: stored, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys, to: "Renamed passkey")

        _ = try await sut.update(draft)

        let sent = try XCTUnwrap(api.lastUpdatedCipher)
        XCTAssertNotNil(stored.key)
        XCTAssertEqual(sent.key, stored.key, "the item key is sent as stored")
        let itemKeys = try mapper.effectiveKeys(for: stored, activeKeys: golden.vaultKeys)
        try assertNameReadable(sent, with: itemKeys, as: "Renamed passkey", notWith: [golden.vaultKeys])
    }

    // MARK: - Keyed organization (fixture organization login)

    func testKeyedOrg_fixtureOrgLogin() async throws {
        let golden = try await GoldenVault.load()
        let stored = golden.cipher(id: GoldenVault.orgLoginId)
        await makeRepository(vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys, records: [stored])
        let draft = try renamedDraft(of: stored, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys, to: "Renamed org login")
        let orgKey = try XCTUnwrap(golden.orgKeys[GoldenVault.orgId])

        _ = try await sut.update(draft)

        let sent = try XCTUnwrap(api.lastUpdatedCipher)
        XCTAssertNotNil(stored.key)
        XCTAssertEqual(sent.key, stored.key)
        let itemKeys = try mapper.effectiveKeys(for: stored, activeKeys: orgKey)
        try assertNameReadable(sent, with: itemKeys, as: "Renamed org login", notWith: [orgKey, golden.vaultKeys])
        XCTAssertEqual(sent.organizationId, GoldenVault.orgId)
        XCTAssertEqual(api.lastUpdatedCipherCollections?.id, GoldenVault.orgLoginId)
        XCTAssertEqual(api.lastUpdatedCipherCollections?.collectionIds, draft.collectionIds)
        XCTAssertFalse(draft.collectionIds.isEmpty)
    }

    // MARK: - Keyless personal (fixture control)

    func testKeylessPersonal_fixtureControl() async throws {
        let golden = try await GoldenVault.load()
        let stored = golden.cipher(id: GoldenVault.controlId)
        await makeRepository(vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys, records: [stored])
        let draft = try renamedDraft(of: stored, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys, to: "Renamed control")

        _ = try await sut.update(draft)

        let sent = try XCTUnwrap(api.lastUpdatedCipher)
        XCTAssertNil(stored.key)
        XCTAssertNil(sent.key, "an item without a key does not gain one")
        try assertNameReadable(sent, with: golden.vaultKeys, as: "Renamed control",
                               notWith: Array(golden.orgKeys.values))
    }

    // MARK: - Keyless organization (synthetic)

    func testKeylessOrg_synthetic() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let orgKey = KeyedCipherBuilder.randomKeys()
        let stored = KeyedCipherBuilder.login(
            id: "org-keyless", name: "Shared", username: "u", organizationId: "org-s",
            collectionIds: ["col-1"], activeKeys: orgKey)
        await makeRepository(vaultKeys: vaultKeys, orgKeys: ["org-s": orgKey], records: [stored])
        let draft = try renamedDraft(of: stored, vaultKeys: vaultKeys, orgKeys: ["org-s": orgKey], to: "Shared, renamed")

        _ = try await sut.update(draft)

        let sent = try XCTUnwrap(api.lastUpdatedCipher)
        XCTAssertNil(sent.key)
        try assertNameReadable(sent, with: orgKey, as: "Shared, renamed", notWith: [vaultKeys])
        XCTAssertEqual(api.lastUpdatedCipherCollections?.collectionIds, ["col-1"])
    }

    // MARK: - An item key that does not unwrap

    func testWrongKey_keyThatDoesNotUnwrap_failsClosed() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let itemKey = KeyedCipherBuilder.randomKeys()
        // `key` is wrapped under a key this vault does not have: unwrapping with the vault key fails.
        let stored = KeyedCipherBuilder.login(
            id: "broken-key", name: "Broken", activeKeys: vaultKeys, itemKey: itemKey,
            wrappingKeys: KeyedCipherBuilder.randomKeys())
        await makeRepository(vaultKeys: vaultKeys, orgKeys: [:], records: [stored])
        var draft = DraftVaultItem(try mapper.map(raw: KeyedCipherBuilder.login(
            id: "broken-key", name: "Broken", activeKeys: vaultKeys, itemKey: itemKey), vaultKeys: vaultKeys).item)
        draft.name = "Edited"

        do {
            _ = try await sut.update(draft)
            XCTFail("Expected itemKeyUnavailable")
        } catch VaultError.itemKeyUnavailable {
            // expected: no fallback to the vault key
        }
        XCTAssertEqual(api.updateCipherCallCount, 0, "nothing is sent")
        XCTAssertEqual(api.updateCipherCollectionsCallCount, 0)
    }

    // MARK: - Adjacency and empty cases

    func testSavingTwice_sendsTheSameKeyString() async throws {
        let golden = try await GoldenVault.load()
        let stored = golden.cipher(id: GoldenVault.passkeyId)
        await makeRepository(vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys, records: [stored])
        var draft = try renamedDraft(of: stored, vaultKeys: golden.vaultKeys, orgKeys: golden.orgKeys, to: "First")
        // The server's answer carries a revision; the mock would echo the request, which has none.
        RepositoryFixtures.answerUpdates(of: api, withRevisionString: try XCTUnwrap(stored.revisionDate))

        _ = try await sut.update(draft)
        let firstKey = try XCTUnwrap(api.lastUpdatedCipher?.key)
        draft.name = "Second"
        _ = try await sut.update(draft)
        let secondKey = try XCTUnwrap(api.lastUpdatedCipher?.key)

        XCTAssertEqual(api.updateCipherCallCount, 2)
        XCTAssertEqual(firstKey, stored.key, "never re-wrapped or re-encoded")
        XCTAssertEqual(secondKey, stored.key, "the record the first save stored still has the same key")
        let itemKeys = try mapper.effectiveKeys(for: stored, activeKeys: golden.vaultKeys)
        XCTAssertEqual(try decryptedName(try XCTUnwrap(api.lastUpdatedCipher), with: itemKeys), "Second")
    }

    func testKeylessRecord_neverGainsAKey() async throws {
        let vaultKeys = KeyedCipherBuilder.randomKeys()
        let stored = KeyedCipherBuilder.login(id: "plain", name: "Plain", activeKeys: vaultKeys)
        await makeRepository(vaultKeys: vaultKeys, orgKeys: [:], records: [stored])
        var draft = try renamedDraft(of: stored, vaultKeys: vaultKeys, orgKeys: [:], to: "Plain, renamed")
        // The server's answer carries a revision; the mock would echo the request, which has none.
        RepositoryFixtures.answerUpdates(of: api, withRevisionString: try XCTUnwrap(stored.revisionDate))

        _ = try await sut.update(draft)
        draft.name = "Plain, again"  // an unchanged draft would go through /partial
        _ = try await sut.update(draft)

        XCTAssertNil(api.lastUpdatedCipher?.key)
        XCTAssertEqual(api.updateCipherCallCount, 2)
    }
}
