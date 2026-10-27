import XCTest
import CryptoKit
@testable import Prizm

/// Every website Prizm saves or creates carries a fresh `uriChecksum`: base64 of the SHA-256 of the
/// exact UTF-8 bytes of the address, encrypted under the key the item's fields are encrypted with.
/// Official Bitwarden clients check it on items that have their own key and hide a website whose
/// checksum is missing or wrong (and drop it on their next save).
///
/// The expectations here are computed with CryptoKit inside the tests, independently of the mapper,
/// and against vectors fixed in advance, so a mapper that hashed the wrong string would not agree.
@MainActor
final class UriChecksumTests: XCTestCase {

    private let vaultKeys = KeyedCipherBuilder.randomKeys()

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

    /// The expected checksum, computed here and not through the mapper.
    private func expectedChecksum(of uri: String) -> String {
        Data(SHA256.hash(data: Data(uri.utf8))).base64EncodedString()
    }

    private func decrypt(_ encString: String?, keys: CryptoKeys,
                         file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let wire = try XCTUnwrap(encString, "missing EncString", file: file, line: line)
        let data = try EncString(string: wire).decrypt(keys: keys)
        return try XCTUnwrap(String(data: data, encoding: .utf8), file: file, line: line)
    }

    private func loginItem(id: String = "login-1", uris: [String]) -> VaultItem {
        VaultItem(
            id: id, name: "Example", isFavorite: false, isDeleted: false,
            creationDate: Date(timeIntervalSince1970: 1_000), revisionDate: Date(timeIntervalSince1970: 2_000),
            content: .login(LoginContent(
                username: "user", password: "secret",
                uris: uris.map { LoginURI(uri: $0, matchType: nil) },
                totp: nil, notes: nil, customFields: []
            ))
        )
    }

    // MARK: - Tracer: a real PUT body through the real client

    func testEditedLogin_putBodyCarriesACorrectChecksumPerWebsite() async throws {
        let client = await makeClient()
        let store = RawCipherStore()
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: client, crypto: await unlockedCrypto(), recordStore: store)
        let item = loginItem(uris: ["https://example.com", "https://example.com/login"])
        await vault.populate(items: [item], folders: [], organizations: [], collections: [], syncedAt: Date())
        // The save is built over the server's stored record of the item.
        try await RepositoryFixtures.seedRecords(for: [item], in: store, vaultKeys: vaultKeys)
        // The echo decrypts with the same keys, so update() can map it.
        StubURLProtocol.responder = { _ in
            .status(200, body: StubURLProtocol.requests.last?.body ?? Data())
        }

        var draft = DraftVaultItem(loginItem(uris: ["https://example.com", "https://example.com/login"]))
        draft.name = "Renamed"
        _ = try await vault.update(draft)

        let put = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(put.method, "PUT")
        let login = try XCTUnwrap(put.jsonBody?["login"] as? [String: Any])
        let uris = try XCTUnwrap(login["uris"] as? [[String: Any]])
        XCTAssertEqual(uris.count, 2)
        for entry in uris {
            let uri = try decrypt(entry["uri"] as? String, keys: vaultKeys)
            let checksum = try decrypt(entry["uriChecksum"] as? String, keys: vaultKeys)
            XCTAssertEqual(checksum, expectedChecksum(of: uri), "checksum of \(uri)")
        }
    }

    // MARK: - Known-answer vectors

    /// Vectors fixed in advance (locked uriChecksum decision); SHA-256 per FIPS 180-4, base64 per
    /// RFC 4648 section 4. The last one is non-ASCII: the hash covers the UTF-8 bytes.
    func testKnownAnswerVectors() {
        let vectors: [(uri: String, checksum: String)] = [
            ("https://example.com",       "EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk="),
            ("https://test.com",          "OWk2vQvwYD1nhLZdA+ltrpBWbDa2JmHyjUEWxRZSS8w="),
            ("https://webauthn.io/",      "25FYYY4LSw8CKWbYR76+mFyEkF8HuR+PMbzkET+z8+Q="),
            ("https://example.com/login", "pGF1jY9OB4Lfpv5mts3QAjxtaJTVa0hmNkeVwhG3gPA="),
            ("https://exämple.com",       "FxOrK5bfYfzD4fBxUJrbg5lEUQwRt+AmBQr/z0KdUqg="),
        ]
        for vector in vectors {
            XCTAssertEqual(CipherMapper.uriChecksumPlaintext(vector.uri), vector.checksum, vector.uri)
        }
    }

    func testEmptyString_vector() {
        XCTAssertEqual(CipherMapper.uriChecksumPlaintext(""), "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
    }

    // MARK: - Mapper-level helpers

    private func loginDraft(uris: [String], id: String = "login-1") -> DraftVaultItem {
        DraftVaultItem(loginItem(id: id, uris: uris))
    }

    /// The `(uri, checksum)` plaintext pairs of the login in `raw`, decrypted under `keys`, in order.
    private func decryptedURIs(of raw: RawCipher, keys: CryptoKeys,
                               file: StaticString = #filePath, line: UInt = #line) throws -> [(uri: String, checksum: String)] {
        let uris = try XCTUnwrap(raw.login?.uris, "login has no uris list", file: file, line: line)
        return try uris.map {
            (try decrypt($0.uri, keys: keys, file: file, line: line),
             try decrypt($0.uriChecksum, keys: keys, file: file, line: line))
        }
    }

    // MARK: - Real data: what the Bitwarden extension and web vault wrote

    /// The golden fixture's own checksums, written by official clients under each item's own key
    /// (or the vault or organization key for the keyless ones), equal what Prizm would write for the
    /// same address. This is the check against data Prizm did not produce.
    func testFixtureChecksums_matchTheFunction() async throws {
        let golden = try await GoldenVault.load()
        let mapper = CipherMapper()
        let ids = [GoldenVault.controlId, GoldenVault.twinId, GoldenVault.passkeyId,
                   GoldenVault.orgLoginId, GoldenVault.archivedId]

        for id in ids {
            let raw = golden.cipher(id: id)
            let active = raw.organizationId.flatMap { golden.orgKeys[$0] } ?? golden.vaultKeys
            let keys = try mapper.effectiveKeys(for: raw, activeKeys: active)

            let uris = try XCTUnwrap(raw.login?.uris, "fixture item \(id) has no uris")
            XCTAssertFalse(uris.isEmpty, "fixture item \(id) has no website to check")
            for entry in uris {
                let uri = try decrypt(entry.uri, keys: keys)
                let checksum = try decrypt(entry.uriChecksum, keys: keys)
                XCTAssertEqual(checksum, CipherMapper.uriChecksumPlaintext(uri), "item \(id), \(uri)")
                XCTAssertEqual(checksum, expectedChecksum(of: uri), "item \(id), \(uri), CryptoKit")
            }
        }
    }

    // MARK: - Empty websites

    func testEmptyWebsite_isNotSent() throws {
        let raw = try CipherMapper().toRawCipher(
            loginDraft(uris: ["", "https://example.com"]), encryptedWith: vaultKeys)

        let sent = try decryptedURIs(of: raw, keys: vaultKeys)

        XCTAssertEqual(sent.map(\.uri), ["https://example.com"])
        XCTAssertEqual(sent.map(\.checksum), [expectedChecksum(of: "https://example.com")])
    }

    func testLoginWithoutWebsites_sendsAnEmptyList() throws {
        let raw = try CipherMapper().toRawCipher(loginDraft(uris: []), encryptedWith: vaultKeys)

        XCTAssertEqual(raw.login?.uris?.count, 0)
    }

    // MARK: - Adjacency, ordering, idempotency

    func testTwoIdenticalWebsites_eachGetAChecksum() throws {
        let raw = try CipherMapper().toRawCipher(
            loginDraft(uris: ["https://example.com", "https://example.com"]), encryptedWith: vaultKeys)

        let entries = try XCTUnwrap(raw.login?.uris)
        XCTAssertEqual(entries.count, 2)
        let checksumsOnTheWire = try entries.map { try XCTUnwrap($0.uriChecksum) }
        XCTAssertNotEqual(checksumsOnTheWire[0], checksumsOnTheWire[1], "each encryption has its own IV")
        let sent = try decryptedURIs(of: raw, keys: vaultKeys)
        XCTAssertEqual(sent.map(\.checksum), Array(repeating: expectedChecksum(of: "https://example.com"), count: 2))
    }

    func testReorderedWebsites_checksumsFollowTheirURI() throws {
        let first = "https://example.com"
        let second = "https://test.com/path"
        let original = try CipherMapper().toRawCipher(loginDraft(uris: [first, second]), encryptedWith: vaultKeys)
        let reordered = try CipherMapper().toRawCipher(loginDraft(uris: [second, first]), encryptedWith: vaultKeys)

        for raw in [original, reordered] {
            for pair in try decryptedURIs(of: raw, keys: vaultKeys) {
                XCTAssertEqual(pair.checksum, expectedChecksum(of: pair.uri), "checksum of \(pair.uri)")
            }
        }
        XCTAssertEqual(try decryptedURIs(of: reordered, keys: vaultKeys).map(\.uri), [second, first])
    }

    func testSavingTwice_samePlaintextFreshCiphertext() throws {
        let draft = loginDraft(uris: ["https://example.com"])
        let mapper = CipherMapper()

        let one = try mapper.toRawCipher(draft, encryptedWith: vaultKeys)
        let two = try mapper.toRawCipher(draft, encryptedWith: vaultKeys)

        XCTAssertEqual(try decryptedURIs(of: one, keys: vaultKeys).map(\.checksum),
                       try decryptedURIs(of: two, keys: vaultKeys).map(\.checksum))
        XCTAssertNotEqual(one.login?.uris?.first?.uriChecksum, two.login?.uris?.first?.uriChecksum)
    }

    // MARK: - Exact string

    func testURIIsHashedAsTyped() throws {
        let typed = "HTTPS://Example.COM/Path/"
        let raw = try CipherMapper().toRawCipher(loginDraft(uris: [typed]), encryptedWith: vaultKeys)

        let sent = try XCTUnwrap(try decryptedURIs(of: raw, keys: vaultKeys).first)

        XCTAssertEqual(sent.uri, typed)
        XCTAssertEqual(sent.checksum, expectedChecksum(of: typed))
        XCTAssertNotEqual(sent.checksum, expectedChecksum(of: typed.lowercased()))
        XCTAssertNotEqual(sent.checksum, expectedChecksum(of: "HTTPS://Example.COM/Path"))
    }

    // MARK: - Create, personal and organization

    func testCreatePersonalAndOrg_carryChecksums() async throws {
        let api = MockPrizmAPIClient()
        let orgKeys = KeyedCipherBuilder.randomKeys()
        let orgKeyCache = OrgKeyCache()
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        let vault = await RepositoryFixtures.vaultRepository(
            apiClient: api, crypto: await unlockedCrypto(), orgKeyCache: orgKeyCache)

        _ = try await vault.create(loginDraft(uris: ["https://example.com", "https://test.com"], id: "new-1"))
        let personal = try XCTUnwrap(api.lastCreatedCipher)
        let personalURIs = try decryptedURIs(of: personal, keys: vaultKeys)
        XCTAssertEqual(personalURIs.map(\.uri), ["https://example.com", "https://test.com"])
        for pair in personalURIs { XCTAssertEqual(pair.checksum, expectedChecksum(of: pair.uri)) }

        var orgDraft = loginDraft(uris: ["https://webauthn.io/"], id: "new-org")
        orgDraft.organizationId = "org-1"
        orgDraft.collectionIds = ["col-a"]
        _ = try await vault.create(orgDraft)
        let org = try XCTUnwrap(api.lastCreatedOrgCipher)
        let orgURIs = try decryptedURIs(of: org, keys: orgKeys)
        XCTAssertEqual(orgURIs.map(\.checksum), ["25FYYY4LSw8CKWbYR76+mFyEkF8HuR+PMbzkET+z8+Q="])
        XCTAssertThrowsError(try decrypt(org.login?.uris?.first?.uriChecksum, keys: vaultKeys),
                             "the organization item's checksum is under the organization key")
    }
}
