import XCTest
@testable import Prizm

/// Tests for `VaultKeyServiceImpl`: the item's effective key from its recorded source, and no
/// fallback to the vault key (openspec change fix-org-attachment-key, design D1).
@MainActor
final class VaultKeyServiceImplTests: XCTestCase {

    private var cache: VaultKeyCache!
    private var orgKeyCache: OrgKeyCache!
    private var mockCrypto: MockPrizmCryptoService!
    private var sut: VaultKeyServiceImpl!

    private let vaultKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0x01, count: 32),
        macKey:        Data(repeating: 0x02, count: 32)
    )
    private let orgKeys = CryptoKeys(
        encryptionKey: Data(repeating: 0x03, count: 32),
        macKey:        Data(repeating: 0x04, count: 32)
    )

    override func setUp() async throws {
        cache       = VaultKeyCache()
        orgKeyCache = OrgKeyCache()
        mockCrypto  = MockPrizmCryptoService()
        mockCrypto._isUnlocked = true
        mockCrypto.stubbedVaultKeys = vaultKeys
        sut         = VaultKeyServiceImpl(cache: cache, orgKeyCache: orgKeyCache, crypto: mockCrypto)
    }

    // MARK: - Resolution

    func test_itemKey_isReturned() async throws {
        let itemKey = Data(repeating: 0xAB, count: 64)
        await cache.populate(sources: ["cipher-1": .itemKey(itemKey)])

        let result = try await sut.cipherKey(for: "cipher-1")
        XCTAssertEqual(result, itemKey)
    }

    func test_itemKey_isReturnedEvenWhileLocked() async throws {
        let itemKey = Data(repeating: 0xCC, count: 64)
        await cache.populate(sources: ["cipher-1": .itemKey(itemKey)])
        mockCrypto._isUnlocked = false

        let result = try await sut.cipherKey(for: "cipher-1")
        XCTAssertEqual(result, itemKey)
    }

    func test_organization_returnsTheOrgKey() async throws {
        await cache.populate(sources: ["shared": .organization(orgId: "org-1")])
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])

        let result = try await sut.cipherKey(for: "shared")
        XCTAssertEqual(result, orgKeys.toData())
        XCTAssertNotEqual(result, vaultKeys.toData())
    }

    func test_organization_readsTheOrgKeyAtUseTime() async throws {
        await cache.populate(sources: ["shared": .organization(orgId: "org-1")])
        await orgKeyCache.replaceAll(with: ["org-1": vaultKeysLikeOldOrgKey])
        await orgKeyCache.replaceAll(with: ["org-1": orgKeys])

        let result = try await sut.cipherKey(for: "shared")
        XCTAssertEqual(result, orgKeys.toData(), "The key of the latest sync, not a copy from before")
    }

    func test_organizationWithoutKey_throwsOrganizationKeyUnavailable() async {
        await cache.populate(sources: ["shared": .organization(orgId: "org-1")])

        do {
            _ = try await sut.cipherKey(for: "shared")
            XCTFail("An org item must never fall back to the vault key")
        } catch VaultError.organizationKeyUnavailable {
            // expected
        } catch {
            XCTFail("Expected organizationKeyUnavailable, got \(error)")
        }
    }

    func test_personal_returnsTheVaultKey() async throws {
        await cache.populate(sources: ["mine": .personal])

        let result = try await sut.cipherKey(for: "mine")
        XCTAssertEqual(result, vaultKeys.encryptionKey + vaultKeys.macKey)
        XCTAssertEqual(result.count, 64, "Effective cipher key must be 64 bytes (encKey ‖ macKey)")
    }

    func test_personal_whileLocked_throwsVaultLocked() async {
        await cache.populate(sources: ["mine": .personal])
        mockCrypto._isUnlocked = false

        do {
            _ = try await sut.cipherKey(for: "mine")
            XCTFail("Expected VaultError.vaultLocked")
        } catch VaultError.vaultLocked {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_unknownItem_throwsCipherKeyUnavailable_neverTheVaultKey() async {
        await cache.populate(sources: ["other": .personal])

        do {
            _ = try await sut.cipherKey(for: "not-in-cache")
            XCTFail("An unknown item must not get the vault key")
        } catch VaultError.cipherKeyUnavailable {
            XCTAssertEqual(VaultError.cipherKeyUnavailable.errorDescription,
                           "Prizm doesn't have the key for this item yet. Sync and try again.")
        } catch {
            XCTFail("Expected cipherKeyUnavailable, got \(error)")
        }
    }

    // MARK: - Personal key (attachments wrapped with it, design D3)

    func test_personalKey_returnsTheVaultKey() async throws {
        let result = try await sut.personalKey()
        XCTAssertEqual(result, vaultKeys.toData())
    }

    func test_personalKey_whileLocked_throwsVaultLocked() async {
        mockCrypto._isUnlocked = false
        do {
            _ = try await sut.personalKey()
            XCTFail("Expected VaultError.vaultLocked")
        } catch VaultError.vaultLocked {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private var vaultKeysLikeOldOrgKey: CryptoKeys {
        CryptoKeys(encryptionKey: Data(repeating: 0x09, count: 32), macKey: Data(repeating: 0x0A, count: 32))
    }
}
