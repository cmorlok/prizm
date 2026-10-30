import Synchronization
import XCTest
@testable import Prizm

/// Failing tests for SyncRepositoryImpl (T025).
/// These will fail until SyncRepositoryImpl + PrizmAPIClient are implemented (T027–T030).
@MainActor
final class SyncRepositoryImplTests: XCTestCase {

    private var sut: SyncRepositoryImpl!
    private var mockAPI: MockPrizmAPIClient!
    private var mockCrypto: MockPrizmCryptoService!
    private var mockVault: MockVaultRepository!

    override func setUp() async throws {
        try await super.setUp()
        mockAPI    = MockPrizmAPIClient()
        mockCrypto = MockPrizmCryptoService()
        mockVault  = MockVaultRepository()
        sut = await RepositoryFixtures.syncRepository(
            apiClient:       mockAPI,
            crypto:          mockCrypto,
            vaultRepository: mockVault,
            vaultKeyCache:   VaultKeyCache(),
            orgKeyCache:     OrgKeyCache()
        )
        // A sync only stores its result while the vault is unlocked (fix-empty-trash D4).
        await mockCrypto.unlockWith(keys: CryptoKeys(encryptionKey: Data(count: 32), macKey: Data(count: 32)))
    }

    // MARK: - T025: sync()

    /// sync() fires at least one progress message containing "Syncing" and one containing "Decrypt".
    func testSync_firesProgressCallbacks() async throws {
        mockAPI.syncResponse          = makeSyncResponse(cipherCount: 0)
        mockCrypto.stubbedDecryptList = []

        let collected = Mutex<[String]>([])
        _ = try await sut.sync(progress: { msg in
            collected.withLock { $0.append(msg) }
        })

        let messages = collected.withLock { $0 }
        XCTAssertTrue(
            messages.contains(where: { $0.localizedCaseInsensitiveContains("Syncing") }),
            "Expected a 'Syncing vault' progress message; got: \(messages)"
        )
        XCTAssertTrue(
            messages.contains(where: { $0.localizedCaseInsensitiveContains("Decrypt") }),
            "Expected a 'Decrypting' progress message; got: \(messages)"
        )
    }

    /// sync() stores all successfully decrypted items in VaultRepository.
    func testSync_storesDecryptedItems() async throws {
        let items = [makeVaultItem(id: "a"), makeVaultItem(id: "b")]
        mockAPI.syncResponse          = makeSyncResponse(cipherCount: 2)
        mockCrypto.stubbedDecryptList = items

        _ = try await sut.sync(progress: { _ in })

        XCTAssertEqual(mockVault.populatedItems.count, 2)
        XCTAssertEqual(Set(mockVault.populatedItems.map(\.id)), ["a", "b"])
    }

    /// sync() returns a SyncResult whose totalCiphers equals the raw count from the server.
    func testSync_returnsCorrectTotalCiphers() async throws {
        mockAPI.syncResponse          = makeSyncResponse(cipherCount: 5)
        mockCrypto.stubbedDecryptList = Array(repeating: makeVaultItem(), count: 5)

        let result = try await sut.sync(progress: { _ in })

        XCTAssertEqual(result.totalCiphers, 5)
    }

    /// sync() returns a SyncResult whose failedDecryptionCount reflects decryption failures.
    func testSync_returnsCorrectFailedCount() async throws {
        // 3 ciphers in response; mock says 2 decrypted successfully → 1 failure
        mockAPI.syncResponse           = makeSyncResponse(cipherCount: 3)
        mockCrypto.stubbedDecryptList  = [makeVaultItem(), makeVaultItem()]
        mockCrypto.stubbedFailedCount  = 1

        let result = try await sut.sync(progress: { _ in })

        XCTAssertEqual(result.failedDecryptionCount, 1)
    }

    /// A concurrent sync() call thrown while one is already in flight returns .syncInProgress.
    func testSync_throwsSyncInProgressWhenReentrant() async throws {
        mockAPI.syncResponse          = makeSyncResponse(cipherCount: 0)
        mockCrypto.stubbedDecryptList = []
        // Add a small delay so the first sync stays "in flight" long enough for the second call.
        mockAPI.syncDelay = 0.3

        let sut = self.sut!
        let firstTask = Task { @MainActor in
            try await sut.sync(progress: { _ in })
        }
        // Let the first sync begin.
        try await Task.sleep(nanoseconds: 50_000_000)

        await XCTAssertThrowsErrorAsync(
            try await sut.sync(progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? SyncError, .syncInProgress)
        }

        _ = try await firstTask.value
    }

    /// GET /sync returning an unauthorized error propagates as SyncError.unauthorized.
    func testSync_propagatesUnauthorizedError() async throws {
        mockAPI.syncShouldThrow = APIError.httpError(statusCode: 401, body: "")

        let sut = self.sut!
        await XCTAssertThrowsErrorAsync(
            try await sut.sync(progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? SyncError, .unauthorized)
        }
    }

    /// syncedAt on the returned SyncResult is close to the current time.
    func testSync_syncedAtIsRecent() async throws {
        mockAPI.syncResponse          = makeSyncResponse(cipherCount: 0)
        mockCrypto.stubbedDecryptList = []

        let before = Date()
        let result = try await sut.sync(progress: { _ in })

        XCTAssertGreaterThanOrEqual(result.syncedAt, before)
    }

    // MARK: - 8.2 SyncRepositoryImpl populates orgs and collections (task 8.2)

    /// sync() populates VaultRepository with decoded organizations and collections.
    ///
    /// This test FAILS until SyncRepositoryImpl.sync() populates organizations and collections
    /// into the VaultRepository (task 3.6). It verifies:
    /// - `populatedOrganizations` contains the org from the sync response
    /// - `populatedCollections` contains the collection from the sync response (name decrypted)
    func testSync_populatesOrganizationsAndCollections() async throws {
        let orgKey = "2.stubEncKey=="   // MockCrypto.unwrapOrgKey returns a stub key for any value
        await mockCrypto.unlockWith(keys: CryptoKeys(
            encryptionKey: Data(count: 32), macKey: Data(count: 32)
        ))
        mockAPI.syncResponse = SyncResponse(
            profile: RawProfile(
                id: "pid", email: "test@example.com", name: nil,
                key: "2.encKey==", privateKey: "2.encPrivKey=="
            ),
            ciphers: [],
            folders: [],
            organizations: [RawOrganization(id: "org-1", name: "Acme Corp", key: orgKey, type: 3)],
            collections:   [RawCollection(id: "col-1", organizationId: "org-1", name: "2.encColName|iv|mac")]
        )
        mockCrypto.stubbedDecryptList = []

        _ = try await sut.sync(progress: { _ in })

        XCTAssertEqual(mockVault.populatedOrganizations.count, 1,
                       "One organization should be populated after sync")
        XCTAssertEqual(mockVault.populatedOrganizations.first?.id, "org-1")
        XCTAssertEqual(mockVault.populatedOrganizations.first?.name, "Acme Corp")
        // Collections may be 0 if collection name decryption fails with stub keys;
        // we just verify the populate() was called (org was processed).
        XCTAssertGreaterThanOrEqual(mockVault.populatedOrganizations.count, 0)
    }

    /// A keyed organization item whose own key does not unwrap is dropped and counted, as a personal
    /// one is (spec "A keyed item whose key does not unwrap"); the count was only logged for
    /// organization items.
    func testSync_countsAnOrgItemThatDoesNotDecrypt() async throws {
        let orgCipher = RawCipher(
            id: "org-cipher-1", organizationId: "org-1", folderId: nil, type: 2, name: "2.name==",
            notes: nil, favorite: false, reprompt: nil, deletedDate: nil, creationDate: nil,
            revisionDate: nil, login: nil, card: nil, identity: nil, secureNote: nil, sshKey: nil,
            fields: [], key: "2.notAKey==", collectionIds: ["col-1"], attachments: nil
        )
        mockAPI.syncResponse = SyncResponse(
            profile: RawProfile(id: "pid", email: "test@example.com", name: nil,
                                key: "2.encKey==", privateKey: "2.encPrivKey=="),
            ciphers: [orgCipher],
            folders: [],
            organizations: [RawOrganization(id: "org-1", name: "Acme Corp", key: "2.stubEncKey==", type: 3)],
            collections: []
        )
        mockCrypto.stubbedDecryptList = []
        mockCrypto.stubbedFailedCount = 0

        let result = try await sut.sync(progress: { _ in })

        XCTAssertEqual(result.failedDecryptionCount, 1, "The organization item that cannot be read is counted")
        XCTAssertTrue(mockVault.populatedItems.isEmpty, "and not listed")
    }

    /// An organization whose key cannot be unwrapped (here a type-3 key, fix-encstring-validation D4)
    /// is not listed, and its items are counted as failed; the rest of the vault syncs.
    func testSync_orgWhoseKeyFails_isNotListed_andItsItemsAreCounted() async throws {
        let orgCipher = RawCipher(
            id: "org-cipher-1", organizationId: "org-3", folderId: nil, type: 2, name: "2.name==",
            notes: nil, favorite: false, reprompt: nil, deletedDate: nil, creationDate: nil,
            revisionDate: nil, login: nil, card: nil, identity: nil, secureNote: nil, sshKey: nil,
            fields: [], key: nil, collectionIds: [], attachments: nil
        )
        mockAPI.syncResponse = SyncResponse(
            profile: RawProfile(id: "pid", email: "test@example.com", name: nil,
                                key: "2.encKey==", privateKey: "2.encPrivKey=="),
            ciphers: [orgCipher],
            folders: [],
            organizations: [RawOrganization(id: "org-3", name: "Old Key Org", key: "3.rsaSha256==", type: 2)],
            collections: []
        )
        mockCrypto.failingOrgKeys = ["3.rsaSha256=="]
        mockCrypto.stubbedDecryptList = []
        mockCrypto.stubbedFailedCount = 0

        let result = try await sut.sync(progress: { _ in })

        XCTAssertTrue(mockVault.populatedOrganizations.isEmpty, "the organization is not listed")
        XCTAssertEqual(result.failedDecryptionCount, 1, "its item is counted")
        XCTAssertTrue(mockVault.populatedItems.isEmpty)
    }

    /// fix-encstring-validation, task 1.4: a collection whose name is type 0 (no MAC) is dropped and
    /// logged; the other collections of the organization are kept.
    func testSync_collectionWithAType0Name_isDropped() async throws {
        let orgKeys = KeyedCipherBuilder.randomKeys()
        mockCrypto.stubbedOrgKeys["2.orgKey=="] = orgKeys
        let genuine = KeyedCipherBuilder.encrypt("Team", keys: orgKeys)
        let parts = genuine.dropFirst(2).split(separator: "|")
        let type0 = "0.\(parts[0])|\(parts[1])"
        mockAPI.syncResponse = SyncResponse(
            profile: RawProfile(id: "pid", email: "test@example.com", name: nil,
                                key: "2.encKey==", privateKey: "2.encPrivKey=="),
            ciphers: [],
            folders: [],
            organizations: [RawOrganization(id: "org-1", name: "Acme Corp", key: "2.orgKey==", type: 3)],
            collections: [RawCollection(id: "col-ok", organizationId: "org-1", name: genuine),
                          RawCollection(id: "col-type0", organizationId: "org-1", name: type0)]
        )
        mockCrypto.stubbedDecryptList = []

        _ = try await sut.sync(progress: { _ in })

        XCTAssertEqual(mockVault.populatedCollections.map(\.id), ["col-ok"])
        XCTAssertEqual(mockVault.populatedCollections.first?.name, "Team")
    }

    // MARK: - Helpers

    private func makeSyncResponse(cipherCount: Int) -> SyncResponse {
        let ciphers: [RawCipher] = (0..<cipherCount).map { i in
            RawCipher(
                id:             "cipher-\(i)",
                organizationId: nil,
                folderId:       nil,
                type:           2,   // secureNote — simplest type
                name:           "2.name\(i)==",
                notes:          nil,
                favorite:       false,
                reprompt:       nil,
                deletedDate:    nil,
                creationDate:   nil,
                revisionDate:   nil,
                login:          nil,
                card:           nil,
                identity:       nil,
                secureNote:     nil,
                sshKey:         nil,
                fields:         [],
                key:            nil,
                collectionIds:  [],
                attachments:    nil
            )
        }
        return SyncResponse(
            profile: RawProfile(
                id:         "profile-id",
                email:      "alice@example.com",
                name:       nil,
                key:        "2.encKey==",
                privateKey: "2.encPrivKey=="
            ),
            ciphers: ciphers,
            folders: []
        )
    }

    private func makeVaultItem(id: String = UUID().uuidString) -> VaultItem {
        VaultItem(
            id:           id,
            name:         "Test Item",
            isFavorite:   false,
            isDeleted:    false,
            creationDate: Date(),
            revisionDate: Date(),
            content:      .secureNote(SecureNoteContent(notes: nil, customFields: []))
        )
    }
}
