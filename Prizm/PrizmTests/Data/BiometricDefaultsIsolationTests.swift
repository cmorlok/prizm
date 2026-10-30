import XCTest
@testable import Prizm

/// fix-biometric-test-isolation: the Touch ID preferences of a unit test stay out of the app's real
/// preferences domain. Unit tests are hosted in the app, so `UserDefaults.standard` is the
/// developer's own Prizm setting, shared by test classes running in parallel processes.
///
/// Each step compares the two keys in `.standard` with their value before the test, so every write
/// to the real store fails, whatever the developer's setting is. The values are put back afterwards.
@MainActor
final class BiometricDefaultsIsolationTests: XCTestCase {

    private static let keys = ["biometricUnlockEnabled", "biometricEnrollmentPromptShown"]

    private var snapshot: [String: Any] = [:]
    private var store: UserDefaults!
    private var mockCrypto: MockPrizmCryptoService!
    private var mockKeychain: MockKeychainService!
    private var sut: AuthRepositoryImpl!

    override func setUp() async throws {
        try await super.setUp()
        snapshot = Self.standardValues()
        store = makePrivateDefaults()
        mockCrypto = MockPrizmCryptoService()
        mockKeychain = MockKeychainService()
        sut = AuthRepositoryImpl(
            apiClient: MockPrizmAPIClient(),
            crypto: mockCrypto,
            keychain: mockKeychain,
            biometricKeychain: MockBiometricKeychainService(),
            vaultKeyCache: VaultKeyCache(),
            orgKeyCache: OrgKeyCache(),
            defaults: store
        )
        seedStoredSession()
    }

    override func tearDown() async throws {
        // Only a key that changed is put back: writing an unchanged value would itself write the
        // real store, and could undo a change the developer made meanwhile (code review 2026-10-30).
        let now = Self.standardValues()
        for key in Self.keys where (now[key] as? NSObject) != (snapshot[key] as? NSObject) {
            if let value = snapshot[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try await super.tearDown()
    }

    private static func standardValues() -> [String: Any] {
        var values: [String: Any] = [:]
        for key in keys { values[key] = UserDefaults.standard.object(forKey: key) }
        return values
    }

    private func assertStandardUnchanged(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let now = Self.standardValues()
        for key in Self.keys {
            XCTAssertEqual(now[key] as? NSObject, snapshot[key] as? NSObject,
                           "\(step) changed \(key) in UserDefaults.standard", file: file, line: line)
        }
    }

    func testEnableDisableAndSignOut_leaveTheRealPreferencesUnchanged() async throws {
        mockCrypto._isUnlocked = true
        try await sut.enableBiometricUnlock()
        assertStandardUnchanged("enableBiometricUnlock")
        XCTAssertTrue(store.bool(forKey: "biometricUnlockEnabled"), "written to the injected store")

        try await sut.disableBiometricUnlock()
        assertStandardUnchanged("disableBiometricUnlock")
        XCTAssertEqual(store.object(forKey: "biometricUnlockEnabled") as? Bool, false)

        try await sut.enableBiometricUnlock()
        try await sut.signOut()
        assertStandardUnchanged("signOut")
        XCTAssertEqual(store.object(forKey: "biometricUnlockEnabled") as? Bool, false)
    }

    // MARK: - View models read the injected store

    /// Run with both values, so one of them always differs from the developer's real setting.
    func testToggleViewModel_readsTheInjectedStore() {
        for enabled in [true, false] {
            store.set(enabled, forKey: "biometricUnlockEnabled")
            let viewModel = BiometricUnlockToggleViewModel(authRepository: MockAuthRepository(), defaults: store)
            XCTAssertEqual(viewModel.isEnabled, enabled)
        }
        assertStandardUnchanged("BiometricUnlockToggleViewModel")
    }

    func testUnlockViewModel_readsTheEnrollmentStateFromTheInjectedStore() async throws {
        for promptShown in [true, false] {
            store.set(false, forKey: "biometricUnlockEnabled")
            store.set(promptShown, forKey: "biometricEnrollmentPromptShown")
            let auth = MockAuthRepository()
            auth.stubbedDeviceBiometricCapable = true
            let viewModel = UnlockViewModel(auth: auth, sync: MockSyncUseCase(), account: Self.account, defaults: store)

            viewModel.password = "TestPassword1!"
            viewModel.unlock()
            let deadline = ContinuousClock.now + .seconds(3)
            while !viewModel.showEnrollmentPrompt, viewModel.flowState != .vault, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }

            XCTAssertEqual(viewModel.showEnrollmentPrompt, !promptShown, "prompt shown before: \(promptShown)")
            if !promptShown {
                viewModel.dismissEnrollmentPrompt()
                XCTAssertTrue(store.bool(forKey: BiometricPreferenceKey.enrollmentPromptShown), "written to the injected store")
            }
            // Both runs end in the vault, so the first one really unlocked rather than timing out.
            let vaultDeadline = ContinuousClock.now + .seconds(3)
            while viewModel.flowState != .vault, ContinuousClock.now < vaultDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(viewModel.flowState, .vault, "prompt shown before: \(promptShown)")
        }
        assertStandardUnchanged("UnlockViewModel")
    }

    private static let account = Account(
        userId: "isolation-user", email: "isolation@example.com", name: nil,
        serverEnvironment: ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil))

    // MARK: - Helpers

    private func seedStoredSession() {
        let userId = "isolation-user"
        mockKeychain.seed(key: "bw.macos:activeUserId", value: userId)
        mockKeychain.seed(key: "bw.macos:\(userId):email", value: "isolation@example.com")
        let env = try! JSONEncoder().encode(ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil))
        mockKeychain.seed(key: "bw.macos:\(userId):serverEnvironment", data: env)
        mockKeychain.seed(key: "bw.macos:\(userId):accessToken", value: "token")
        mockKeychain.seed(key: "bw.macos:\(userId):refreshToken", value: "refresh")
    }
}
