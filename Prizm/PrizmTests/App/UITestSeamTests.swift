#if DEBUG
import LocalAuthentication
import XCTest
@testable import Prizm

/// Unit tests for the DEBUG-only XCUITest seam (openspec change `fix-ui-test-target`, design D1–D3).
@MainActor
final class UITestSeamTests: XCTestCase {

    // MARK: - Launch state (D1)

    func test_launchState_noTestArgument_isNil() {
        XCTAssertNil(UITestFixtures.launchState(from: ["Prizm", "--debug-mode"]))
    }

    func test_launchState_parsesEachState() {
        XCTAssertEqual(UITestFixtures.launchState(from: ["Prizm", "--ui-test-vault"]), .vault)
        XCTAssertEqual(UITestFixtures.launchState(from: ["Prizm", "--ui-test-locked"]), .locked)
        XCTAssertEqual(UITestFixtures.launchState(from: ["Prizm", "--ui-test-signed-out"]), .signedOut)
    }

    func test_launchState_mostRestrictiveWins() {
        // A test that asks for "signed out" must never see a seeded or locked session.
        XCTAssertEqual(UITestFixtures.launchState(from: ["--ui-test-vault", "--ui-test-signed-out"]), .signedOut)
        XCTAssertEqual(UITestFixtures.launchState(from: ["--ui-test-vault", "--ui-test-locked"]), .locked)
    }

    // MARK: - Fixture keychain (D2)

    func test_keychain_signedOut_isEmpty() {
        let keychain = UITestFixtures.keychain(for: .signedOut)
        XCTAssertThrowsError(try keychain.read(key: KeychainKey.activeUserId))
    }

    func test_keychain_lockedAndVault_holdFixtureAccount() throws {
        for state in [UITestFixtures.LaunchState.locked, .vault] {
            let keychain = UITestFixtures.keychain(for: state)
            let auth = AuthRepositoryImpl(
                apiClient: MockPrizmAPIClient(),
                crypto: MockPrizmCryptoService(),
                keychain: keychain,
                biometricKeychain: InMemoryBiometricKeychainService(),
                vaultKeyCache: VaultKeyCache(),
                orgKeyCache: OrgKeyCache()
            )
            let account = try XCTUnwrap(auth.storedAccount(), "state \(state)")
            XCTAssertEqual(account.email, UITestFixtures.accountEmail)
            XCTAssertEqual(account.serverEnvironment.base, UITestFixtures.serverURL)
        }
    }

    func test_isolateBiometricDefaults_overridesWithoutWriting() throws {
        let suite = "prizm.uitest.seam.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "biometricUnlockEnabled")
        defaults.set(false, forKey: "biometricEnrollmentPromptShown")

        // The argument domain is shared by the whole process: restore it afterwards.
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        UITestFixtures.isolateBiometricDefaults(defaults)

        XCTAssertFalse(defaults.bool(forKey: "biometricUnlockEnabled"), "reads as off during the test")
        XCTAssertTrue(defaults.bool(forKey: "biometricEnrollmentPromptShown"))
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(stored["biometricUnlockEnabled"] as? Bool, true, "the stored value is untouched")
        XCTAssertEqual(stored["biometricEnrollmentPromptShown"] as? Bool, false)
    }

    // MARK: - In-memory keychains (D2)

    func test_inMemoryKeychain_writeReadDelete() throws {
        let keychain = InMemoryKeychainService()
        XCTAssertThrowsError(try keychain.read(key: "k")) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
        try keychain.write(data: Data("one".utf8), key: "k")
        try keychain.write(data: Data("two".utf8), key: "k")
        XCTAssertEqual(try keychain.read(key: "k"), Data("two".utf8))
        try keychain.delete(key: "k")
        try keychain.delete(key: "k") // deleting a missing item is a no-op
        XCTAssertThrowsError(try keychain.read(key: "k"))
    }

    func test_inMemoryBiometricKeychain_writeReadDelete() async throws {
        let keychain = InMemoryBiometricKeychainService()
        do {
            _ = try await keychain.readBiometric(key: "k")
            XCTFail("Expected itemNotFound")
        } catch {
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
        try keychain.writeBiometric(data: Data("secret".utf8), key: "k")
        let first = try await keychain.readBiometric(key: "k")
        let second = try await keychain.readBiometric(key: "k", context: LAContext())
        XCTAssertEqual(first, Data("secret".utf8))
        XCTAssertEqual(second, Data("secret".utf8))
        try keychain.deleteBiometric(key: "k")
        try keychain.deleteBiometric(key: "k")
        do {
            _ = try await keychain.readBiometric(key: "k")
            XCTFail("Expected itemNotFound after delete")
        } catch {
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
    }

    // MARK: - Fixture data (D3)

    func test_fixtureItems_coverTheJourneys() {
        let items = UITestFixtures.items
        let ids = Set(items.map(\.id))
        // Existing items, relied on by VerificationCodeJourneyTests.
        XCTAssertTrue(ids.isSuperset(of: ["alpha", "beta", "gamma", "delta", "zeta"]))
        // Added for the other journeys.
        XCTAssertTrue(ids.isSuperset(of: ["kappa", "card1", "ident1", "note1"]))
        XCTAssertTrue(items.contains { $0.isFavorite }, "Favorites journey needs a favourite")
        XCTAssertFalse(items.contains { if case .sshKey = $0.content { return true }; return false },
                       "The SSH Key category must stay empty for the empty-state journey")
        XCTAssertFalse(items.first { $0.id == "kappa" }?.attachments.isEmpty ?? true,
                       "Attachment journeys need an attachment entry")
    }

    func test_fixtureItems_newItemsAddNoCodes() {
        // The Codes list (VerificationCodeJourneyTests) must not change.
        let withSeeds = UITestFixtures.items.filter {
            if case .login(let login) = $0.content { return login.totp != nil }
            return false
        }
        XCTAssertEqual(Set(withSeeds.map(\.id)), ["alpha", "beta", "delta", "zeta"])
    }

    func test_blockedItem_isASecureNoteThatCannotBeEdited() {
        let blocked = UITestFixtures.blockedItem

        XCTAssertEqual(blocked.editBlock, .unsupportedFormat)
        guard case .secureNote = blocked.content else { return XCTFail("a blocked fixture is a secure note") }
        // No TOTP seed and no other fixture's id: the Codes list and the other journeys stay unchanged.
        // The flag is off in unit tests, so `items` holds only the other fixtures.
        let otherIds = Set((UITestFixtures.items + [UITestFixtures.orgItemInFolder]).map(\.id))
        XCTAssertFalse(otherIds.contains(blocked.id))
    }

    // MARK: - Stored server records

    func test_rawRecords_oneMappableRecordPerFixtureItem() throws {
        let items = UITestFixtures.items + [UITestFixtures.orgItemInFolder]

        let records = UITestFixtures.rawRecords(for: items)

        XCTAssertEqual(records.map(\.id), items.map(\.id))
        let mapper = CipherMapper()
        for (item, record) in zip(items, records) {
            let mapped = try mapper.map(
                raw: record, vaultKeys: UITestFixtures.vaultKeys, orgKeys: UITestFixtures.orgKeys).item
            XCTAssertEqual(mapped.name, item.name, "record of \(item.id)")
            XCTAssertEqual(mapped.organizationId, item.organizationId)
        }
        XCTAssertEqual(records.first { $0.id == "omega" }?.organizationId, "org-acme")
        // The org record is built under the organization key: without that key it is not readable.
        let omega = try XCTUnwrap(records.first { $0.id == "omega" })
        XCTAssertThrowsError(try mapper.map(raw: omega, vaultKeys: UITestFixtures.vaultKeys, orgKeys: [:]))
    }
}
#endif
