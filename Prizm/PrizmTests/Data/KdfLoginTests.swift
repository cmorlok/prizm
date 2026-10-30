import XCTest
@testable import Prizm

/// Login and unlock with the KDF rules of openspec change `fix-kdf-derivation-and-validation`:
/// settings are checked before anything is derived or sent (D2), the salt is the server's or the
/// normalized email (D3), and the settings and salt that worked are stored (D6).
@MainActor
final class KdfLoginTests: XCTestCase {

    private var sut: AuthRepositoryImpl!
    private var api: MockPrizmAPIClient!
    private var crypto: MockPrizmCryptoService!
    private var keychain: MockKeychainService!

    private let userId = "user-001"
    private let pbkdf2 = KdfParams(type: .pbkdf2, iterations: 600_000, memory: nil, parallelism: nil)

    override func setUp() async throws {
        try await super.setUp()
        api      = MockPrizmAPIClient()
        crypto   = MockPrizmCryptoService()
        keychain = MockKeychainService()
        sut = AuthRepositoryImpl(apiClient: api, crypto: crypto, keychain: keychain,
                                 biometricKeychain: MockBiometricKeychainService(),
                                 vaultKeyCache: VaultKeyCache(), orgKeyCache: OrgKeyCache(),
                                 defaults: makePrivateDefaults())
        try await sut.setServerEnvironment(ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil))
        api.tokenResponse = tokenResponse()
    }

    private func tokenResponse(unlock: TokenResponse.MasterPasswordUnlock? = nil) -> TokenResponse {
        TokenResponse(accessToken: "at", refreshToken: "rt", tokenType: "Bearer", expiresIn: 3600,
                      privateKey: nil, twoFactorToken: nil, twoFactorProviders: nil,
                      userId: userId, email: "user@example.com", name: nil,
                      masterPasswordUnlock: unlock ?? .init(
                        kdf: WireKdfSettings(kdfType: 0, iterations: 600_000, memory: nil, parallelism: nil),
                        masterKeyEncryptedUserKey: "2.k|k|k", salt: "user@example.com"),
                      legacyUserKey: nil)
    }

    private func login(_ email: String = "user@example.com") async throws {
        _ = try await sut.loginWithPassword(email: email, masterPassword: Data("pw".utf8))
    }

    private func storedString(_ name: String) -> String? {
        (try? keychain.read(key: "bw.macos:\(userId):\(name)")).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func assertLoginFails(with expected: AuthError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await login()
            XCTFail("Login must be refused", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AuthError, expected, file: file, line: line)
        }
        XCTAssertTrue(api.identityTokenEmails.isEmpty, "Nothing may be sent to /connect/token", file: file, line: line)
        XCTAssertTrue(crypto.derivations.isEmpty, "No key may be derived", file: file, line: line)
    }

    // MARK: - 3.3 Refused settings at login

    func testLogin_pbkdf2WithOneIteration_isRefusedAsTooWeak() async {
        api.preLoginResponse = PreLoginResponse(kdf: 0, kdfIterations: 1, kdfMemory: nil, kdfParallelism: nil)
        await assertLoginFails(with: .kdfSettingsTooWeak)
    }

    func testLogin_argon2idWith15MiB_isRefusedAsTooWeak() async {
        api.preLoginResponse = PreLoginResponse(kdf: 1, kdfIterations: 3, kdfMemory: 15, kdfParallelism: 4)
        await assertLoginFails(with: .kdfSettingsTooWeak)
    }

    func testLogin_negativeValue_isRefusedAsInvalid() async {
        api.preLoginResponse = PreLoginResponse(kdf: 1, kdfIterations: 3, kdfMemory: -64, kdfParallelism: 4)
        await assertLoginFails(with: .invalidKdfSettings)
    }

    func testLogin_unknownKdfType_isRefusedAsInvalid() async {
        api.preLoginResponse = PreLoginResponse(kdf: 2, kdfIterations: 600_000, kdfMemory: nil, kdfParallelism: nil)
        await assertLoginFails(with: .invalidKdfSettings)
    }

    // MARK: - 3.4 Refused settings at unlock

    func testUnlock_storedSettingsBelowMinimum_areRefused() async throws {
        let env = ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil)
        let weak = KdfParams(type: .pbkdf2, iterations: 1000, memory: nil, parallelism: nil)
        keychain.seed(key: "bw.macos:activeUserId", value: userId)
        keychain.seed(key: "bw.macos:\(userId):email", value: "user@example.com")
        keychain.seed(key: "bw.macos:\(userId):encUserKey", value: "2.k|k|k")
        keychain.seed(key: "bw.macos:\(userId):kdfParams", data: try JSONEncoder().encode(weak))
        keychain.seed(key: "bw.macos:\(userId):serverEnvironment", data: try JSONEncoder().encode(env))

        do {
            _ = try await sut.unlockWithPassword(Data("pw".utf8))
            XCTFail("Unlock must be refused")
        } catch {
            XCTAssertEqual(error as? AuthError, .kdfSettingsTooWeak)
        }
        XCTAssertTrue(crypto.derivations.isEmpty, "No key may be derived")
    }

    // MARK: - 4.1 / 4.2 Email normalization

    func testLogin_typedEmailIsTrimmedAndLowercased_forPreloginSaltAndUsername() async throws {
        try await login("  User@Example.COM \n")

        XCTAssertEqual(api.preLoginEmails, ["user@example.com"])
        XCTAssertEqual(api.identityTokenEmails, ["user@example.com"])
        XCTAssertEqual(crypto.derivations.map(\.salt), ["user@example.com"])
    }

    /// The real crypto service normalizes the salt too, so every spelling gives the same key; a
    /// non-ASCII email gives the bytes of Unicode default lowercasing, which Rust `to_lowercase`
    /// (SDK) also applies. Expected value: Python `hashlib.pbkdf2_hmac` over
    /// `"ümit.çelik@exämple.com"` (`str.lower()`, same Unicode mapping), 5000 iterations.
    func testMasterKey_nonASCIIEmail_matchesUnicodeLowercasing() async throws {
        let service = PrizmCryptoServiceImpl()
        let kdf = KdfParams(type: .pbkdf2, iterations: 5000, memory: nil, parallelism: nil)
        let password = Data("67t9b5g67$%Dh89n".utf8)

        let key = try await service.makeMasterKey(password: password, salt: " Ümit.Çelik@Exämple.COM ", kdf: kdf)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "c8148adafeef1fb485f0175697bf34b27f37e1b0603e1bac7e6b130a1cb50d13")

        let plain  = try await service.makeMasterKey(password: password, salt: "user@example.com", kdf: kdf)
        let spaced = try await service.makeMasterKey(password: password, salt: " User@Example.com ", kdf: kdf)
        XCTAssertEqual(plain, spaced)
    }

    // MARK: - 4.3 Server salt

    func testLogin_usesServerSalt_normalized() async throws {
        api.preLoginResponse = PreLoginResponse(kdfParams: pbkdf2, salt: " Other@Example.com ")
        try await login()
        XCTAssertEqual(crypto.derivations.map(\.salt), ["other@example.com"])
    }

    func testLogin_withoutServerSalt_usesEmail() async throws {
        for salt in [nil, "", "  "] as [String?] {
            crypto.derivations = []
            api.preLoginResponse = PreLoginResponse(kdfParams: pbkdf2, salt: salt)
            try await login("User@Example.com")
            XCTAssertEqual(crypto.derivations.map(\.salt), ["user@example.com"], "salt \(String(describing: salt))")
        }
    }

    // MARK: - 4.4 / 5.4 Stored salt and settings

    func testLogin_storesTheSettingsAndSaltThatWorked() async throws {
        let argon = KdfParams(type: .argon2id, iterations: 3, memory: 64, parallelism: 4)
        api.preLoginResponse = PreLoginResponse(kdfParams: argon, salt: "Other@Example.com")
        // The token response reports different settings; the ones that derived the key are kept.
        api.tokenResponse = tokenResponse(unlock: .init(
            kdf: WireKdfSettings(kdfType: 0, iterations: 600_000, memory: nil, parallelism: nil),
            masterKeyEncryptedUserKey: "2.k|k|k", salt: "other@example.com"))

        try await login()

        let stored = try keychain.read(key: "bw.macos:\(userId):kdfParams")
        XCTAssertEqual(try JSONDecoder().decode(KdfParams.self, from: stored), argon)
        XCTAssertEqual(storedString("masterPasswordSalt"), "other@example.com")
    }

    /// A legacy token response without `Kdf*` used to store 600 000 iterations; now the prelogin
    /// settings that worked are stored.
    func testLogin_legacyTokenWithoutKdf_storesPreloginSettings() async throws {
        let pbkdf2Low = KdfParams(type: .pbkdf2, iterations: 100_000, memory: nil, parallelism: nil)
        api.preLoginResponse = PreLoginResponse(kdfParams: pbkdf2Low)
        api.tokenResponse = TokenResponse(accessToken: "at", refreshToken: "rt", tokenType: "Bearer", expiresIn: 3600,
                                          key: "2.k|k|k", privateKey: nil, kdf: nil, kdfIterations: nil,
                                          kdfMemory: nil, kdfParallelism: nil, twoFactorToken: nil,
                                          twoFactorProviders: nil, userId: userId, email: "user@example.com", name: nil)
        try await login()

        let stored = try keychain.read(key: "bw.macos:\(userId):kdfParams")
        XCTAssertEqual(try JSONDecoder().decode(KdfParams.self, from: stored), pbkdf2Low)
    }

    func testLoginWithTOTP_storesTheSaltOfThePasswordStep() async throws {
        api.preLoginResponse = PreLoginResponse(kdfParams: pbkdf2, salt: "Other@Example.com")
        let token = api.tokenResponse
        api.tokenResponse = nil
        api.tokenTwoFactorProviders = [0]
        try await login()
        api.tokenResponse = token

        _ = try await sut.loginWithTOTP(code: "123456", rememberDevice: false)

        XCTAssertEqual(storedString("masterPasswordSalt"), "other@example.com")
    }

    private func seedSession(salt: String?) throws {
        let env = ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil)
        keychain.seed(key: "bw.macos:activeUserId", value: userId)
        keychain.seed(key: "bw.macos:\(userId):email", value: "User@Example.com")
        keychain.seed(key: "bw.macos:\(userId):encUserKey", value: "2.k|k|k")
        keychain.seed(key: "bw.macos:\(userId):kdfParams", data: try JSONEncoder().encode(pbkdf2))
        keychain.seed(key: "bw.macos:\(userId):serverEnvironment", data: try JSONEncoder().encode(env))
        if let salt { keychain.seed(key: "bw.macos:\(userId):masterPasswordSalt", value: salt) }
    }

    func testUnlock_usesStoredSalt() async throws {
        try seedSession(salt: "other@example.com")
        _ = try await sut.unlockWithPassword(Data("pw".utf8))
        XCTAssertEqual(crypto.derivations.map(\.salt), ["other@example.com"])
    }

    func testUnlock_withoutStoredSalt_fallsBackToNormalizedEmail() async throws {
        try seedSession(salt: nil)
        _ = try await sut.unlockWithPassword(Data("pw".utf8))
        XCTAssertEqual(crypto.derivations.map(\.salt), ["user@example.com"])
    }

    /// Only a missing salt falls back to the email; any other Keychain failure stops the unlock, so
    /// a locked or damaged Keychain never derives a key from the wrong salt (review 2026-10-30).
    func testUnlock_saltReadFails_isReported_withoutDeriving() async throws {
        try seedSession(salt: "other@example.com")
        keychain.readErrors["bw.macos:\(userId):masterPasswordSalt"] = KeychainError.unexpectedStatus(-25308)
        do {
            _ = try await sut.unlockWithPassword(Data("pw".utf8))
            XCTFail("The Keychain failure must be reported")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials, "Got \(error)")
        }
        XCTAssertTrue(crypto.derivations.isEmpty)
    }

    func testSignOut_deletesStoredSalt() async throws {
        try seedSession(salt: "other@example.com")
        try await sut.signOut()
        XCTAssertTrue(keychain.deletedKeys.contains("bw.macos:\(userId):masterPasswordSalt"))
        XCTAssertNil(storedString("masterPasswordSalt"))
    }
}
