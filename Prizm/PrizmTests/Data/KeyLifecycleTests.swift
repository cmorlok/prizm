import Synchronization
import XCTest
@testable import Prizm

/// When key material is zeroed and cleared, and what debug logs may contain (openspec change
/// harden-key-lifecycle-and-logging).
@MainActor
final class KeyLifecycleTests: XCTestCase {

    private var sut: AuthRepositoryImpl!
    private var gate: SessionGateImpl!
    private var api: MockPrizmAPIClient!
    private var crypto: MockPrizmCryptoService!
    private var keychain: MockKeychainService!
    private var vaultKeyCache: VaultKeyCache!
    private var orgKeyCache: OrgKeyCache!
    private var defaults: UserDefaults!
    private var zeroed: [AuthRepositoryImpl.ZeroedKey] = []

    private let env = ServerEnvironment(base: URL(string: "https://vault.example.com")!, overrides: nil)

    override func setUp() async throws {
        try await super.setUp()
        api = MockPrizmAPIClient()
        crypto = MockPrizmCryptoService()
        keychain = MockKeychainService()
        vaultKeyCache = VaultKeyCache()
        orgKeyCache = OrgKeyCache()
        defaults = makePrivateDefaults()
        gate = SessionGateImpl()
        sut = AuthRepositoryImpl(apiClient: api, crypto: crypto, keychain: keychain,
                                 biometricKeychain: MockBiometricKeychainService(),
                                 vaultKeyCache: vaultKeyCache, orgKeyCache: orgKeyCache,
                                 defaults: defaults, gate: gate)
        zeroed = []
        sut.zeroedKeyObserver = { [weak self] in self?.zeroed.append($0) }
        try await sut.setServerEnvironment(env)
        crypto.stubbedMasterKey = Data(repeating: 0x5A, count: 32)
        crypto.stubbedStretchedKeys = CryptoKeys(encryptionKey: Data(repeating: 0x6B, count: 32),
                                                 macKey: Data(repeating: 0x7C, count: 32))
        api.preLoginResponse = PreLoginResponse(kdf: 0, kdfIterations: 600_000, kdfMemory: nil, kdfParallelism: nil)
    }

    private func tokenResponse(twoFactorProviders: [Int]? = nil) -> TokenResponse {
        TokenResponse(accessToken: "at", refreshToken: "rt", tokenType: "Bearer", expiresIn: 3600,
                      key: "2.k|k|k", privateKey: nil, kdf: 0, kdfIterations: 600_000,
                      kdfMemory: nil, kdfParallelism: nil, twoFactorToken: nil,
                      twoFactorProviders: twoFactorProviders, userId: "u1", email: "a@example.com", name: nil)
    }

    /// Every transient key buffer named in `labels` was zeroed in place, i.e. in the owner's own
    /// buffer, not in a copy made by copy-on-write.
    private func assertZeroedInPlace(_ labels: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        for label in labels {
            let entries = zeroed.filter { $0.label == label }
            XCTAssertFalse(entries.isEmpty, "\(label) was not zeroed", file: file, line: line)
            for entry in entries {
                XCTAssertTrue(entry.inPlace, "\(label) was zeroed in a copy, not in place", file: file, line: line)
                XCTAssertTrue(entry.bytes.allSatisfy { $0 == 0 }, "\(label) still holds key bytes", file: file, line: line)
            }
        }
    }

    /// A lock as `RootViewModel` runs it: the gate closes first, the teardown opens it last
    /// (lock-state-machine, design D1).
    private func lock() async {
        gate.end()
        await sut.lockVault()
        gate.open()
    }

    // MARK: - 1.1 / 1.3 One teardown path

    func testSignOut_clearsBothKeyCaches() async throws {
        await orgKeyCache.replaceAll(with: ["org-1": CryptoKeys(encryptionKey: Data(repeating: 1, count: 32),
                                                                macKey: Data(repeating: 2, count: 32))])
        await vaultKeyCache.populate(sources: ["c1": .itemKey(Data(repeating: 3, count: 64))])

        let zeroedOrgKeys = Mutex<[OrgKeyCache.ZeroedOrgKey]>([])
        await orgKeyCache.setZeroedObserver { key in zeroedOrgKeys.withLock { $0.append(key) } }
        let zeroedItemKeys = Mutex<[(bytes: Data, inPlace: Bool)]>([])
        await vaultKeyCache.setZeroedObserver { bytes, inPlace in zeroedItemKeys.withLock { $0.append((bytes, inPlace)) } }

        try await sut.signOut()

        let orgKeys = await orgKeyCache.snapshot()
        XCTAssertTrue(orgKeys.isEmpty)
        // The removed org key's own buffers hold only zeros, not a copy made by copy-on-write.
        let zeroed = zeroedOrgKeys.withLock { $0 }
        XCTAssertEqual(zeroed.count, 1)
        XCTAssertTrue(zeroed.allSatisfy(\.inPlace), "Zeroed in a copy, not in place")
        XCTAssertTrue(zeroed.allSatisfy { ($0.encryptionKey + $0.macKey).allSatisfy { $0 == 0 } })
        let zeroedItems = zeroedItemKeys.withLock { $0 }
        XCTAssertEqual(zeroedItems.count, 1)
        XCTAssertTrue(zeroedItems.allSatisfy { $0.inPlace && $0.bytes.allSatisfy { $0 == 0 } },
                      "The per-item key's own buffer holds only zeros")
        let itemKey = await vaultKeyCache.key(for: "c1")
        XCTAssertNil(itemKey)
    }

    /// Task 1.2: "Sign in with a different account" on the unlock screen goes through the same
    /// sign-out, so no key of the previous account survives it.
    func testSignInWithDifferentAccount_clearsBothKeyCaches() async throws {
        await orgKeyCache.replaceAll(with: ["org-1": CryptoKeys(encryptionKey: Data(repeating: 1, count: 32),
                                                                macKey: Data(repeating: 2, count: 32))])
        await vaultKeyCache.populate(sources: ["c1": .itemKey(Data(repeating: 3, count: 64))])
        let unlock = UnlockViewModel(auth: sut, sync: MockSyncUseCase(),
                                     account: Account(userId: "u1", email: "a@example.com", name: nil,
                                                      serverEnvironment: env),
                                     defaults: defaults, gate: gate)

        // The root wires this to its sign-out (lock-state-machine, D1); here straight to the
        // repository's, whose key teardown is what this test is about.
        let signedOut = expectation(description: "signed out")
        unlock.onSignOutRequested = { [sut] in
            Task { try? await sut!.signOut(); signedOut.fulfill() }
        }

        unlock.signInWithDifferentAccount()
        await fulfillment(of: [signedOut], timeout: 5)

        let orgKeys = await orgKeyCache.snapshot()
        XCTAssertTrue(orgKeys.isEmpty)
        let itemKey = await vaultKeyCache.key(for: "c1")
        XCTAssertNil(itemKey)
    }

    func testLockVault_clearsBothKeyCaches() async throws {
        await orgKeyCache.replaceAll(with: ["org-1": CryptoKeys(encryptionKey: Data(repeating: 1, count: 32),
                                                                macKey: Data(repeating: 2, count: 32))])

        await lock()

        let orgKeys = await orgKeyCache.snapshot()
        XCTAssertTrue(orgKeys.isEmpty)
    }

    // MARK: - 3.1 Master and stretched keys after login and unlock

    func testLogin_zeroesMasterAndStretchedKeys() async throws {
        api.tokenResponse = tokenResponse()

        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())

        assertZeroedInPlace(["masterKey", "stretchedEncryptionKey", "stretchedMacKey"])
    }

    func testLogin_failure_stillZeroesTheKeys() async throws {
        api.tokenShouldThrow = IdentityTokenError.invalidCredentials

        _ = try? await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())

        assertZeroedInPlace(["masterKey", "stretchedEncryptionKey", "stretchedMacKey"])
    }

    func testUnlock_wrongPassword_zeroesTheKeys() async throws {
        api.tokenResponse = tokenResponse()
        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        await lock()
        zeroed = []
        crypto.decryptSymmetricKeyError = PrizmCryptoServiceError.invalidEncUserKey

        _ = try? await sut.unlockWithPassword(Data("wrong".utf8), flow: gate.begin())

        assertZeroedInPlace(["masterKey", "stretchedEncryptionKey", "stretchedMacKey"])
    }

    // MARK: - A lock during a login or unlock (lock-during-unlock-sync, D6)

    private final class Gate: Sendable {
        let entered = Mutex(false)
        let released = Mutex(false)
    }

    /// Holds the next login or unlock inside its key derivation until the gate is released.
    private func holdKeyDerivation() -> Gate {
        let gate = Gate()
        crypto.whileDecryptingUserKey = {
            gate.entered.withLock { $0 = true }
            while !gate.released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        return gate
    }

    private func waitUntilEntered(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testLockDuringUnlock_loadsNoKeys() async throws {
        api.tokenResponse = tokenResponse()
        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        await lock()
        let gate = holdKeyDerivation()
        defer { gate.released.withLock { $0 = true } }

        let unlock = Task { try await self.sut.unlockWithPassword(Data("pw".utf8), flow: self.gate.begin()) }
        try await waitUntilEntered(gate)
        await lock()
        gate.released.withLock { $0 = true }

        do {
            _ = try await unlock.value
            XCTFail("The unlock must not succeed after a lock")
        } catch AuthError.lockedWhileUnlocking {}
        XCTAssertFalse(crypto.isUnlocked, "No keys loaded behind the lock screen")
        assertZeroedInPlace(["refusedVaultEncryptionKey", "refusedVaultMacKey"])
    }

    /// A lock that comes while the keys are being loaded unloads them, and the original buffers are
    /// zeroed in place (third verification, W2).
    func testLockWhileLoadingKeys_unloadsAndZeroesThem() async throws {
        api.tokenResponse = tokenResponse()
        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        await lock()
        zeroed = []
        crypto.whileUnlockingWith = { [weak self, crypto] in
            crypto?.whileUnlockingWith = nil
            await self?.lock()
        }

        do {
            _ = try await sut.unlockWithPassword(Data("pw".utf8), flow: gate.begin())
            XCTFail("The unlock must not succeed after a lock")
        } catch AuthError.lockedWhileUnlocking {}
        XCTAssertFalse(crypto.isUnlocked)
        assertZeroedInPlace(["unloadedVaultEncryptionKey", "unloadedVaultMacKey"])
    }

    func testSignOutDuringLogin_loadsNoKeys() async throws {
        api.tokenResponse = tokenResponse()
        let gate = holdKeyDerivation()
        defer { gate.released.withLock { $0 = true } }

        let login = Task { try await self.sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: self.gate.begin()) }
        try await waitUntilEntered(gate)
        try await sut.signOut()
        gate.released.withLock { $0 = true }

        do {
            _ = try await login.value
            XCTFail("The login must not succeed after a sign-out")
        } catch AuthError.lockedWhileUnlocking {}
        XCTAssertFalse(crypto.isUnlocked, "No keys loaded behind the login screen")
    }

    // MARK: - 3.2 Keys held for the two-factor step

    private func startTwoFactor() async throws {
        api.tokenResponse = tokenResponse(twoFactorProviders: [0])
        let result = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        guard case .requiresTwoFactor = result else { return XCTFail("Expected the 2FA step") }
        zeroed = []
    }

    func testTwoFactor_success_zeroesThePendingKeys() async throws {
        try await startTwoFactor()
        api.tokenResponse = tokenResponse()

        _ = try await sut.loginWithTOTP(code: "123456", rememberDevice: false)

        assertZeroedInPlace(["pendingEncryptionKey", "pendingMacKey"])
    }

    func testTwoFactor_cancel_zeroesThePendingKeys() async throws {
        try await startTwoFactor()

        sut.cancelTwoFactor()

        assertZeroedInPlace(["pendingEncryptionKey", "pendingMacKey"])
    }

    /// A lock discards an unfinished two-factor step and zeroes its keys (lock-during-unlock-sync).
    func testTwoFactor_lock_zeroesThePendingKeys() async throws {
        try await startTwoFactor()

        await lock()

        assertZeroedInPlace(["pendingEncryptionKey", "pendingMacKey"])
    }

    /// A login that reaches the two-factor step after a lock keeps nothing: the stretched keys are
    /// zeroed and no two-factor step is pending (lock-during-unlock-sync, D6).
    func testTwoFactorChallengeAfterALock_keepsNoKeys() async throws {
        api.tokenResponse = tokenResponse(twoFactorProviders: [0])
        api.whileRequestingToken = { [weak self] in await self?.lock() }

        do {
            _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
            XCTFail("The login must not continue after a lock")
        } catch AuthError.lockedWhileUnlocking {}
        assertZeroedInPlace(["stretchedEncryptionKey", "stretchedMacKey"])
        api.whileRequestingToken = nil
        do {
            _ = try await sut.loginWithTOTP(code: "123456", rememberDevice: false)
            XCTFail("No two-factor step may be pending")
        } catch {}
    }

    func testTwoFactor_signOut_zeroesThePendingKeys() async throws {
        try await startTwoFactor()

        try await sut.signOut()

        assertZeroedInPlace(["pendingEncryptionKey", "pendingMacKey"])
    }

    // MARK: - 4.1 Debug logging allow-list

    func testTokenParamsDebugDescription_containsNoSecrets() {
        let params = ["grant_type": "password", "username": "alice@example.com", "password": "hash==",
                      "scope": "api offline_access", "client_id": "desktop", "deviceType": "7",
                      "deviceIdentifier": "device-uuid-1", "deviceName": "macos",
                      "twoFactorToken": "654321", "twoFactorProvider": "0", "twoFactorRemember": "true"]

        let text = PrizmAPIClientImpl.debugDescription(ofTokenParams: params)

        for secret in ["alice@example.com", "hash==", "654321", "device-uuid-1"] {
            XCTAssertFalse(text.contains(secret), "\(secret) must not be logged")
        }
        for allowed in ["grant_type=password", "client_id=desktop", "twoFactorProvider=0"] {
            XCTAssertTrue(text.contains(allowed), "\(allowed) should be logged")
        }
    }
    // MARK: - Flow tokens from the first step (lock-state-machine, design D2, gap 4)

    /// The sign-in took its token before the server setup; a lock during that setup makes the
    /// login load no keys, even though the auth layer only starts afterwards.
    func testLoginWithAFlowStartedBeforeALock_loadsNoKeys() async throws {
        api.tokenResponse = tokenResponse()
        let flow = gate.begin()
        await lock()

        do {
            _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: flow)
            XCTFail("A sign-in started before a lock must not load keys")
        } catch AuthError.lockedWhileUnlocking {}
        XCTAssertFalse(crypto.isUnlocked)
    }

    func testUnlockWithAFlowStartedBeforeALock_loadsNoKeys() async throws {
        api.tokenResponse = tokenResponse()
        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        await lock()
        let flow = gate.begin()
        await lock()

        do {
            _ = try await sut.unlockWithPassword(Data("pw".utf8), flow: flow)
            XCTFail("An unlock started before a lock must not load keys")
        } catch AuthError.lockedWhileUnlocking {}
        XCTAssertFalse(crypto.isUnlocked)
    }

    // MARK: - Token refresh during an unlock (lock-state-machine, design D3, gap 3)

    private func keychainString(_ name: String) -> String? {
        (try? keychain.read(key: KeychainKey.user("u1", name))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// "Sign Out" while an unlock refreshes the token: the refreshed tokens of the signed-out account
    /// reach neither the Keychain nor the API client.
    func testSignOutDuringTheUnlocksRefresh_writesNoTokensBack() async throws {
        api.tokenResponse = tokenResponse()
        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        await lock()
        api.refreshRotatedRefreshToken = "rotated-rt"
        api.whileRefreshing = { [sut, gate] in
            gate?.end()
            try? await sut?.signOut()
            gate?.open()
        }

        do {
            _ = try await sut.unlockWithPassword(Data("pw".utf8), flow: gate.begin())
            XCTFail("An unlock overtaken by a sign-out must not succeed")
        } catch AuthError.lockedWhileUnlocking {}

        XCTAssertNil(keychainString("accessToken"))
        XCTAssertNil(keychainString("refreshToken"))
        XCTAssertNil(api.storedAccessToken, "The API client holds no token of the signed-out account")
        XCTAssertFalse(crypto.isUnlocked)
    }

    /// A locked vault leaves no bearer token in the network layer; the next unlock installs one
    /// again (code review C3).
    func testLock_removesTheAccessTokenFromTheAPIClient() async throws {
        api.tokenResponse = tokenResponse()
        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        XCTAssertNotNil(api.storedAccessToken)

        await lock()

        XCTAssertNil(api.storedAccessToken)
    }

    /// A lock while an unlock refreshes the token: the account stays signed in, so the rotated tokens
    /// are kept in the Keychain, but the API client gets none and no keys stay loaded.
    func testLockDuringTheUnlocksRefresh_keepsTheRotatedTokensOnlyInTheKeychain() async throws {
        api.tokenResponse = tokenResponse()
        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        await lock()
        api.refreshRotatedRefreshToken = "rotated-rt"
        api.whileRefreshing = { [sut, gate] in
            gate?.end()
            await sut?.lockVault()
            gate?.open()
        }

        do {
            _ = try await sut.unlockWithPassword(Data("pw".utf8), flow: gate.begin())
            XCTFail("An unlock overtaken by a lock must not succeed")
        } catch AuthError.lockedWhileUnlocking {}

        XCTAssertEqual(keychainString("accessToken"), "refreshed-access-token")
        XCTAssertEqual(keychainString("refreshToken"), "rotated-rt")
        XCTAssertNil(api.storedAccessToken, "The API client gets no token of an overtaken unlock")
        XCTAssertFalse(crypto.isUnlocked)
    }

    /// No lock: the refreshed token is stored and installed, as before.
    func testUnlockWithRefresh_installsTheRefreshedToken() async throws {
        api.tokenResponse = tokenResponse()
        _ = try await sut.loginWithPassword(email: "a@example.com", masterPassword: Data("pw".utf8), flow: gate.begin())
        await lock()

        _ = try await sut.unlockWithPassword(Data("pw".utf8), flow: gate.begin())

        XCTAssertEqual(keychainString("accessToken"), "refreshed-access-token")
        XCTAssertEqual(api.storedAccessToken, "refreshed-access-token")
    }
}

/// Keys built from a 64-byte blob get their own buffers, so each half can be zeroed in place (review
/// of harden-key-lifecycle-and-logging: org keys and biometric-unlocked keys were slices).
final class KeyHalvesBufferTests: XCTestCase {

    func testCryptoKeysFromData_halvesHaveOwnBuffers() throws {
        var blob = Data((0..<64).map { UInt8($0) })
        let keys = try XCTUnwrap(CryptoKeys(data: blob))
        blob.resetBytes(in: blob.indices)

        XCTAssertEqual(keys.encryptionKey, Data((0..<32).map { UInt8($0) }), "Zeroing the blob must not touch the keys")
        XCTAssertEqual(keys.macKey, Data((32..<64).map { UInt8($0) }))
        XCTAssertEqual(keys.macKey.startIndex, 0, "Not a slice of the blob (a suffix slice starts at 32)")
    }
}

/// `decryptSymmetricKey` returns keys in their own buffers (task 3.4).
final class UserKeyBufferTests: XCTestCase {

    func testDecryptSymmetricKey_returnsIndependentBuffers() async throws {
        let stretched = CryptoKeys(encryptionKey: Data(repeating: 0x21, count: 32), macKey: Data(repeating: 0x43, count: 32))
        let userKey = Data((0..<64).map { UInt8($0) })
        let encUserKey = try EncString.encrypt(data: userKey, keys: stretched).toString()

        let crypto = PrizmCryptoServiceImpl()
        let scratch = Mutex<(bytes: Data, inPlace: Bool)?>(nil)
        await crypto.setScratchZeroedObserver { bytes, inPlace in scratch.withLock { $0 = (bytes, inPlace) } }

        let keys = try await crypto.decryptSymmetricKey(encUserKey: encUserKey, stretchedKeys: stretched)

        // The 64-byte scratch buffer is zeroed in place (task 3.4).
        let zeroedScratch = try XCTUnwrap(scratch.withLock { $0 })
        XCTAssertTrue(zeroedScratch.inPlace)
        XCTAssertEqual(zeroedScratch.bytes, Data(count: 64))

        XCTAssertEqual(keys.encryptionKey, userKey.prefix(32))
        XCTAssertEqual(keys.macKey, Data(userKey.suffix(32)))
        // Fresh buffers, not slices of the decrypted 64-byte buffer, which is zeroed.
        XCTAssertEqual(keys.encryptionKey.startIndex, 0)
        XCTAssertEqual(keys.macKey.startIndex, 0)
    }

}
