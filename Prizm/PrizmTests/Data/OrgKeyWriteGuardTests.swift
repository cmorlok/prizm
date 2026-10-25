import Synchronization
import XCTest
@testable import Prizm

/// Org items are only ever encrypted with their org key, and the org keys stay available while a
/// sync runs (openspec change fix-org-key-required-on-write).
@MainActor
final class OrgKeyWriteGuardTests: XCTestCase {

    private var sut: VaultRepositoryImpl!
    private var mockAPI: MockPrizmAPIClient!
    private var mockCrypto: MockPrizmCryptoService!
    private var orgKeyCache: OrgKeyCache!

    private let vaultKeys = CryptoKeys(encryptionKey: Data(repeating: 0x11, count: 32), macKey: Data(repeating: 0x22, count: 32))
    private let orgKeys = CryptoKeys(encryptionKey: Data(repeating: 0x33, count: 32), macKey: Data(repeating: 0x44, count: 32))

    private let personalItem = VaultItem(
        id: "personal", name: "Mine", isFavorite: false, isDeleted: false,
        creationDate: Date(), revisionDate: Date(),
        content: .secureNote(SecureNoteContent(notes: nil, customFields: []))
    )
    private let orgItem = VaultItem(
        id: "shared", name: "Shared", isFavorite: false, isDeleted: false,
        creationDate: Date(), revisionDate: Date(),
        content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
        organizationId: "org-1", collectionIds: ["col-a"]
    )

    override func setUp() async throws {
        try await super.setUp()
        mockAPI = MockPrizmAPIClient()
        mockCrypto = MockPrizmCryptoService()
        orgKeyCache = OrgKeyCache()
        sut = VaultRepositoryImpl(apiClient: mockAPI, crypto: mockCrypto, orgKeyCache: orgKeyCache)
        await mockCrypto.unlockWith(keys: vaultKeys)
        mockCrypto.stubbedVaultKeys = vaultKeys  // unlockWith(keys:) does not set the returned keys
        await sut.populate(items: [personalItem, orgItem], folders: [], organizations: [], collections: [], syncedAt: Date())
    }

    private func assertOrgKeyUnavailable(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case VaultError.organizationKeyUnavailable = error else {
            return XCTFail("Expected organizationKeyUnavailable, got \(error)", file: file, line: line)
        }
    }

    private func decryptedName(_ cipher: RawCipher?, with keys: CryptoKeys) throws -> String? {
        let name = try EncString(string: try XCTUnwrap(cipher).name)
        return String(data: try name.decrypt(keys: keys), encoding: .utf8)
    }

    // MARK: - 1.1 / 1.2 No fallback to the vault key

    func testUpdate_orgItemWithoutOrgKey_throwsAndSendsNothing() async throws {
        do {
            _ = try await sut.update(DraftVaultItem(orgItem))
            XCTFail("Expected organizationKeyUnavailable")
        } catch {
            assertOrgKeyUnavailable(error)
        }
        XCTAssertEqual(mockAPI.updateCipherCallCount, 0, "No PUT may be sent")
        XCTAssertEqual(mockAPI.updateCipherCollectionsCallCount, 0)
    }

    func testCreate_orgDraftWithoutOrgKey_throwsAndSendsNothing() async throws {
        var draft = DraftVaultItem.blank(type: .secureNote)
        draft.name = "New shared"
        draft.organizationId = "org-1"
        draft.collectionIds = ["col-a"]

        do {
            _ = try await sut.create(draft)
            XCTFail("Expected organizationKeyUnavailable")
        } catch {
            assertOrgKeyUnavailable(error)
        }
        XCTAssertEqual(mockAPI.createOrgCipherCallCount, 0, "No POST may be sent")
        XCTAssertEqual(mockAPI.createCipherCallCount, 0)
    }

    // MARK: - 1.4 Regression guards

    func testUpdate_personalItemWithoutAnyOrgKeys_usesTheVaultKey() async throws {
        var draft = DraftVaultItem(personalItem)
        draft.name = "Mine, renamed"

        _ = try await sut.update(draft)

        XCTAssertEqual(try decryptedName(mockAPI.lastUpdatedCipher, with: vaultKeys), "Mine, renamed")
        XCTAssertNil(mockAPI.lastUpdatedCipher?.organizationId)
    }

    func testUpdate_orgItemWithItsKey_usesTheOrgKey() async throws {
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])
        var draft = DraftVaultItem(orgItem)
        draft.name = "Shared, renamed"

        _ = try await sut.update(draft)

        XCTAssertEqual(try decryptedName(mockAPI.lastUpdatedCipher, with: orgKeys), "Shared, renamed")
        XCTAssertThrowsError(try decryptedName(mockAPI.lastUpdatedCipher, with: vaultKeys))
    }
}

/// `OrgKeyCache.replaceAll(with:)` (design D2).
final class OrgKeyCacheReplaceAllTests: XCTestCase {

    private func key(_ byte: UInt8) -> CryptoKeys {
        CryptoKeys(encryptionKey: Data(repeating: byte, count: 32), macKey: Data(repeating: byte, count: 32))
    }

    func testReplaceAll_replacesTheWholeMap() async {
        let cache = OrgKeyCache()
        await cache.store(key: key(1), for: "org-old")

        await cache.replaceAll(with: ["org-new": key(2)])

        let snapshot = await cache.snapshot()
        XCTAssertEqual(Set(snapshot.keys), ["org-new"])
        XCTAssertEqual(snapshot["org-new"]?.encryptionKey, Data(repeating: 2, count: 32))
    }

    /// The replaced keys are zeroed inside the cache; a snapshot taken before keeps its own copy
    /// (copy on write), as with `clear()` (SECURITY.md).
    func testReplaceAll_earlierSnapshotKeepsItsCopy() async {
        let cache = OrgKeyCache()
        await cache.store(key: key(7), for: "org-1")
        let before = await cache.snapshot()

        await cache.replaceAll(with: [:])

        XCTAssertEqual(before["org-1"]?.encryptionKey, Data(repeating: 7, count: 32))
        let after = await cache.snapshot()
        XCTAssertTrue(after.isEmpty)
    }
}

/// The sync swaps the org keys in one step (design D2).
@MainActor
final class SyncOrgKeySwapTests: XCTestCase {

    private var sut: SyncRepositoryImpl!
    private var mockAPI: MockPrizmAPIClient!
    private var mockCrypto: MockPrizmCryptoService!
    private var orgKeyCache: OrgKeyCache!

    private let previousKey = CryptoKeys(encryptionKey: Data(repeating: 0x55, count: 32), macKey: Data(repeating: 0x66, count: 32))

    override func setUp() async throws {
        try await super.setUp()
        mockAPI = MockPrizmAPIClient()
        mockCrypto = MockPrizmCryptoService()
        orgKeyCache = OrgKeyCache()
        sut = SyncRepositoryImpl(apiClient: mockAPI, crypto: mockCrypto, vaultRepository: MockVaultRepository(),
                                 vaultKeyCache: VaultKeyCache(), orgKeyCache: orgKeyCache)
        await mockCrypto.unlockWith(keys: CryptoKeys(encryptionKey: Data(count: 32), macKey: Data(count: 32)))
        mockCrypto.stubbedDecryptList = []
        await orgKeyCache.replaceAll(with: ["org-1": previousKey])
    }

    private func syncResponse(organizations: [RawOrganization]) -> SyncResponse {
        SyncResponse(
            profile: RawProfile(id: "pid", email: "test@example.com", name: nil, key: "2.encKey==", privateKey: "2.encPrivKey=="),
            ciphers: [], folders: [], organizations: organizations, collections: []
        )
    }

    // MARK: - 2.2 Never an empty key set during a sync

    func testSync_concurrentReaderNeverSeesAnEmptyKeySet() async throws {
        mockAPI.syncResponse = syncResponse(organizations: [
            RawOrganization(id: "org-1", name: "One", key: "2.k1", type: 2),
            RawOrganization(id: "org-2", name: "Two", key: "2.k2", type: 2),
        ])
        mockCrypto.unwrapOrgKeyDelay = 0.05
        let sawEmpty = Mutex(false)
        let done = Mutex(false)
        let snapshots = Mutex(0)
        let cache = orgKeyCache!

        let reader = Task.detached {
            while !done.withLock({ $0 }) {
                if await cache.snapshot().isEmpty { sawEmpty.withLock { $0 = true } }
                snapshots.withLock { $0 += 1 }
                await Task.yield()
            }
        }
        _ = try await sut.sync(progress: { _ in })
        done.withLock { $0 = true }
        await reader.value

        // The unwrap is held for 2 × 50 ms; the reader must actually have read during the sync,
        // or "never saw empty" would prove nothing.
        XCTAssertGreaterThan(snapshots.withLock { $0 }, 10, "The reader must run while the sync runs")
        XCTAssertFalse(sawEmpty.withLock { $0 }, "A save during the sync would have found no org key")
        let keys = await orgKeyCache.snapshot()
        XCTAssertEqual(Set(keys.keys), ["org-1", "org-2"])
    }

    // MARK: - 2.3 A failure before the swap keeps the previous keys

    /// A sync that fails as a whole keeps the previous keys, together with the previous items.
    func testSync_failingSync_keepsThePreviousKeys() async throws {
        mockAPI.syncShouldThrow = URLError(.notConnectedToInternet)

        _ = try? await sut.sync(progress: { _ in })

        let keys = await orgKeyCache.snapshot()
        XCTAssertEqual(keys["org-1"]?.encryptionKey, previousKey.encryptionKey)
    }

    /// When the org step fails, the sync still completes without org items, so the old org keys
    /// have no use and go (harden-key-lifecycle-and-logging, D2).
    func testSync_privateKeyFailure_dropsTheOrgKeys() async throws {
        mockAPI.syncResponse = syncResponse(organizations: [RawOrganization(id: "org-1", name: "One", key: "2.k1", type: 2)])
        mockCrypto.decryptRSAPrivateKeyError = PrizmCryptoServiceError.invalidEncUserKey

        _ = try await sut.sync(progress: { _ in })

        let keys = await orgKeyCache.snapshot()
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - 2.4 An org that left the sync has no key afterwards

    func testSync_withoutOrganizations_removesTheOldKeys() async throws {
        mockAPI.syncResponse = syncResponse(organizations: [])

        _ = try await sut.sync(progress: { _ in })

        let keys = await orgKeyCache.snapshot()
        XCTAssertTrue(keys.isEmpty, "The user left every organization")
    }

    func testSync_orgMissingFromResponse_hasNoKey() async throws {
        mockAPI.syncResponse = syncResponse(organizations: [RawOrganization(id: "org-2", name: "Two", key: "2.k2", type: 2)])

        _ = try await sut.sync(progress: { _ in })

        let keys = await orgKeyCache.snapshot()
        XCTAssertEqual(Set(keys.keys), ["org-2"])
    }

    // MARK: - An org without a key is not offered (review follow-up)

    func testSync_orgWhoseKeyFails_isNotListed() async throws {
        let repository = MockVaultRepository()
        sut = SyncRepositoryImpl(apiClient: mockAPI, crypto: mockCrypto, vaultRepository: repository,
                                 vaultKeyCache: VaultKeyCache(), orgKeyCache: orgKeyCache)
        mockAPI.syncResponse = syncResponse(organizations: [
            RawOrganization(id: "org-1", name: "One", key: "2.k1", type: 2),
            RawOrganization(id: "org-2", name: "Two", key: "2.broken", type: 2),
        ])
        mockCrypto.failingOrgKeys = ["2.broken"]

        _ = try await sut.sync(progress: { _ in })

        XCTAssertEqual(repository.populatedOrganizations.map(\.id), ["org-1"])
    }
}

/// The edit sheet shows the org-key error and keeps the user's input (task 3.1).
@MainActor
final class ItemEditOrgKeyErrorTests: XCTestCase {

    private struct FailingEdit: EditVaultItemUseCase {
        func execute(draft: DraftVaultItem) async throws -> VaultItem {
            throw VaultError.organizationKeyUnavailable
        }
    }

    func testSave_orgKeyUnavailable_showsMessageAndKeepsDraft() async throws {
        let item = VaultItem(
            id: "shared", name: "Shared", isFavorite: false, isDeleted: false,
            creationDate: Date(), revisionDate: Date(),
            content: .secureNote(SecureNoteContent(notes: nil, customFields: [])),
            organizationId: "org-1"
        )
        let sut = ItemEditViewModel(item: item, useCase: FailingEdit())
        sut.draft.name = "Edited name"

        sut.save()
        let deadline = ContinuousClock.now + .milliseconds(500)
        while sut.saveError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(sut.saveError, "This item's organization can't be accessed right now. Lock and unlock Prizm, then try again.")
        XCTAssertEqual(sut.draft.name, "Edited name", "The user's input stays")
        XCTAssertFalse(sut.isDismissed, "The sheet stays open")
    }
}
