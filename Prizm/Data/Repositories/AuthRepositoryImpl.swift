import Foundation
import LocalAuthentication
import os.log

// MARK: - AuthRepositoryImpl

/// Concrete implementation of `AuthRepository`.
///
/// Orchestrates the full Bitwarden login flow:
///   1. POST `/identity/accounts/prelogin/password` → KDF params
///   2. Derive master key (PBKDF2 or Argon2id) locally
///   3. POST `/connect/token` → access + refresh tokens
///   4. Decrypt encUserKey → vault symmetric keys
///   5. Unlock `PrizmCryptoServiceImpl` with vault keys
///   6. Persist tokens + metadata in Keychain
///
/// Two-factor flow: `loginWithPassword` returns `.requiresTwoFactor` and stores
/// pending state in-memory; `loginWithTOTP` completes the challenge.
///
/// Thread safety: all mutable state is read/written on the calling actor.
/// `@MainActor` annotation ensures single-threaded access during tests and UI.
@MainActor
final class AuthRepositoryImpl: AuthRepository, EmbeddedBiometricUnlock {

    // MARK: - Dependencies

    private let apiClient:  any PrizmAPIClientProtocol
    private let crypto:     any PrizmCryptoService
    private let keychain:   any KeychainService
    private let biometricKeychain: any BiometricKeychainService

    private let logger = Logger(subsystem: "com.prizm", category: "AuthRepository")

    // MARK: - Server configuration

    private(set) var serverEnvironment: ServerEnvironment?

    // MARK: - Pending 2FA state
    // Set by loginWithPassword when the server requests 2FA; consumed by loginWithTOTP.

    private struct PendingTwoFactor {
        let email:         String
        let passwordHash:  String
        let kdfParams:     KdfParams
        let salt:          String
        // `var` so cancelTwoFactor() can zero the key buffers before releasing the struct
        // (Constitution §III). Swift ARC does not guarantee immediate deallocation on nil.
        var stretchedKeys: CryptoKeys
        let deviceId:      String
    }
    private var pendingTwoFactor: PendingTwoFactor?

    // MARK: - Key caches
    // Cleared by lockVault(), the one teardown path for lock, sign-out and "sign in with a
    // different account" (harden-key-lifecycle-and-logging, D1).

    private let vaultKeyCache: VaultKeyCache
    private let orgKeyCache:   OrgKeyCache

    /// Holds the Touch ID preferences (`biometricUnlockEnabled`, `biometricEnrollmentPromptShown`).
    /// Required, with no `.standard` default, so a unit test cannot write the developer's real
    /// settings by leaving it out (fix-biometric-test-isolation, D1).
    private let defaults: UserDefaults

    // MARK: - Init

    init(
        apiClient: any PrizmAPIClientProtocol,
        crypto:    any PrizmCryptoService,
        keychain:  any KeychainService,
        biometricKeychain: any BiometricKeychainService,
        vaultKeyCache: VaultKeyCache,
        orgKeyCache:   OrgKeyCache,
        defaults:      UserDefaults
    ) {
        self.apiClient = apiClient
        self.crypto    = crypto
        self.keychain  = keychain
        self.biometricKeychain = biometricKeychain
        self.vaultKeyCache = vaultKeyCache
        self.orgKeyCache   = orgKeyCache
        self.defaults      = defaults
    }

    // MARK: - Locks during a login or unlock

    /// Counts locks and sign-outs. A login or unlock that started before one must not load its keys
    /// afterwards (lock-during-unlock-sync, D6).
    private var lockEpoch = 0

    /// Loads `keys` into the crypto service unless a lock or sign-out came since `epoch`; on success
    /// `keys` is left empty.
    ///
    /// Security goal: a lock stays in effect even when a login or unlock that was already running
    /// finishes its key derivation afterwards; otherwise its keys would stay loaded behind the lock
    /// or login screen (and could, for example, be enrolled for Touch ID). If a lock comes while the
    /// keys are being loaded, they are unloaded again. Refused keys are zeroed in place.
    private func loadVaultKeys(_ keys: inout CryptoKeys, startedAt epoch: Int) async throws {
        guard epoch == lockEpoch else {
            zero(&keys.encryptionKey, "refusedVaultEncryptionKey")
            zero(&keys.macKey, "refusedVaultMacKey")
            logger.info("Keys not loaded: the vault was locked while unlocking")
            throw AuthError.lockedWhileUnlocking
        }
        await crypto.unlockWith(keys: keys)
        guard epoch == lockEpoch else {
            await crypto.lockVault()
            // The crypto service zeroed its copy; this buffer is the original and now ours alone.
            zero(&keys.encryptionKey, "unloadedVaultEncryptionKey")
            zero(&keys.macKey, "unloadedVaultMacKey")
            logger.info("Keys unloaded: the vault was locked while they were loaded")
            throw AuthError.lockedWhileUnlocking
        }
        // The crypto service now holds the keys. Dropping the caller's reference leaves it the only
        // holder, so a later `lockVault()` zeroes the keys in place instead of a copy-on-write copy
        // while the caller's local still points at the original (the unlock functions keep running
        // across the token refresh).
        keys = CryptoKeys(encryptionKey: Data(), macKey: Data())
    }

    // MARK: - Zeroing transient keys

    /// A key buffer as it was right after zeroing; reported to `zeroedKeyObserver` in DEBUG builds.
    struct ZeroedKey {
        let label: String
        let bytes: Data
        /// False when copy-on-write gave the zeroing its own copy, which leaves the original intact.
        let inPlace: Bool
    }

    #if DEBUG
    /// Test seam: called after each transient key buffer is zeroed.
    var zeroedKeyObserver: ((ZeroedKey) -> Void)?
    #endif

    /// Zeroes a transient key buffer (master key, stretched keys, pending 2FA keys) in place.
    ///
    /// Security goal: derived key material does not stay on the heap after use (Constitution §III).
    /// Swift `Data` is copy-on-write: zeroing reaches the original only while this is its sole
    /// reference, so callers zero after every other holder is gone. Intentionally NOT done:
    /// copies made inside Foundation, CommonCrypto or the crypto actor cannot be reached.
    private func zero(_ data: inout Data, _ label: String) {
        #if DEBUG
        let before = data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        #endif
        data.resetBytes(in: data.indices)
        #if DEBUG
        let after = data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        zeroedKeyObserver?(ZeroedKey(label: label, bytes: data, inPlace: before == after))
        #endif
    }

    /// Zeroes the keys held for the two-factor step and ends it. Mutates the stored struct, so the
    /// stored buffers are zeroed, not a copy.
    private func clearPendingTwoFactor() {
        guard pendingTwoFactor != nil else { return }
        zero(&pendingTwoFactor!.stretchedKeys.encryptionKey, "pendingEncryptionKey")
        zero(&pendingTwoFactor!.stretchedKeys.macKey, "pendingMacKey")
        pendingTwoFactor = nil
    }

    // MARK: - Server configuration

    func validateServerURL(_ urlString: String) throws {
        // Strip trailing slash for normalisation.
        let trimmed = urlString.hasSuffix("/") ? String(urlString.dropLast()) : urlString
        // Only HTTPS is permitted — Constitution §III requires all vault communication
        // to use TLS. Allowing http:// would expose the master password hash and tokens
        // to network interception even on "trusted" local networks.
        guard let url = URL(string: trimmed),
              url.scheme == "https",
              url.host != nil else {
            throw AuthError.invalidURL
        }
    }

    func setServerEnvironment(_ environment: ServerEnvironment) async throws {
        serverEnvironment = environment
        await apiClient.setBaseURL(environment.base)
    }

    // MARK: - Login

    func loginWithPassword(email typedEmail: String, masterPassword: Data) async throws -> LoginResult {
        // Normalized once, as the official clients do (`email.trim().toLowerCase()`), and used for
        // prelogin, the salt fallback and the token `username` (fix-kdf-derivation-and-validation, D3).
        let email = Self.normalized(typedEmail)
        logger.info("Login attempt for \(email, privacy: .private)")
        let epoch = lockEpoch
        guard let env = serverEnvironment else {
            throw AuthError.serverUnreachable
        }
        // A new attempt replaces an unfinished two-factor step; zero its keys first.
        clearPendingTwoFactor()

        // Step 1: Fetch KDF params.
        logger.info("Step 1: fetching KDF params for \(email, privacy: .private)")
        let preLogin   = try await apiClient.preLogin(email: email)
        guard let kdfParams = preLogin.kdfParams else {
            logger.error("Login refused: prelogin sent no usable KDF settings")
            throw AuthError.invalidKdfSettings
        }
        // The server's salt when it sends one, else the email: the SDK's rule
        // (`password_prelogin_response.rs`), D3. Equal to the email for every account today.
        let salt = preLogin.salt.map(Self.normalized).flatMap { $0.isEmpty ? nil : $0 } ?? email
        if DebugConfig.isEnabled {
            logger.debug("[debug] KDF type=\(String(describing: kdfParams.type), privacy: .public) serverSalt=\(salt != email, privacy: .public)")
        }

        // Step 2: Derive master key locally — never sent to server.
        // `masterPassword` is `Data` so we can zero it after the KDF call (Constitution §III).
        logger.info("Step 2: deriving master key (KDF)")
        var masterKey  = try await deriveMasterKey(password: masterPassword, salt: salt, kdf: kdfParams)
        defer { zero(&masterKey, "masterKey") }
        if DebugConfig.isEnabled {
            logger.debug("[debug] master key derived (\(masterKey.count, privacy: .public) bytes)")
        }

        // Step 3: Stretch master key into separate enc + mac keys (HKDF).
        logger.info("Step 3: stretching master key (HKDF)")
        var stretched  = try await crypto.stretchKey(masterKey: masterKey)
        // Zeroed on every exit, unless handed over to the two-factor step, which then owns them
        // (zeroing this copy there would only zero a copy-on-write duplicate).
        var stretchedHandedOver = false
        defer {
            if !stretchedHandedOver {
                zero(&stretched.encryptionKey, "stretchedEncryptionKey")
                zero(&stretched.macKey, "stretchedMacKey")
            }
        }
        if DebugConfig.isEnabled {
            logger.debug("[debug] stretched key: encKey=\(stretched.encryptionKey.count, privacy: .public) bytes, macKey=\(stretched.macKey.count, privacy: .public) bytes")
        }

        // Step 4: Compute server authentication hash.
        // Per Bitwarden Security Whitepaper §4 + RFC 8018 §5.2 (PBKDF2):
        // A second PBKDF2 round is applied over the masterKey using the plaintext
        // password as input, producing a value the server can verify without storing —
        // or ever receiving — the raw master key. The master key never leaves the device.
        logger.info("Step 4: computing server authentication hash")
        let serverHash = try await crypto.makeServerHash(
            masterKey: masterKey,
            password:  masterPassword
        )
        if DebugConfig.isEnabled {
            logger.debug("[debug] server hash computed (\(serverHash.count, privacy: .public) chars)")
        }

        // Step 5: Request identity token.
        logger.info("Step 5: requesting identity token")
        let deviceId   = try deviceIdentifier()
        let tokenResp: TokenResponse
        do {
            tokenResp = try await apiClient.identityToken(
                email:             email,
                passwordHash:      serverHash,
                deviceIdentifier:  deviceId,
                twoFactorToken:    nil,
                twoFactorProvider: nil,
                twoFactorRemember: false
            )
        } catch let err as IdentityTokenError {
            switch err {
            case .twoFactorRequired(let providers):
                // Not kept for a two-factor step behind a lock; `stretched` is zeroed on the way out.
                guard epoch == lockEpoch else { throw AuthError.lockedWhileUnlocking }
                pendingTwoFactor = PendingTwoFactor(
                    email:         email,
                    passwordHash:  serverHash,
                    kdfParams:     kdfParams,
                    salt:          salt,
                    stretchedKeys: stretched,
                    deviceId:      deviceId
                )
                stretchedHandedOver = true
                logger.info("2FA required")
                return .requiresTwoFactor(twoFactorMethod(from: providers))
            case .twoFactorCodeInvalid:
                logger.error("Login failed: \(AuthError.invalidTwoFactorCode.localizedDescription, privacy: .public)")
                throw AuthError.invalidTwoFactorCode
            case .invalidCredentials:
                logger.error("Login failed: \(AuthError.invalidCredentials.localizedDescription, privacy: .public)")
                throw AuthError.invalidCredentials
            }
        }

        if let providers = tokenResp.twoFactorProviders, !providers.isEmpty {
            // Server returned a 2FA challenge inside a 200 response (test-mock path).
            guard epoch == lockEpoch else { throw AuthError.lockedWhileUnlocking }
            pendingTwoFactor = PendingTwoFactor(
                email:         email,
                passwordHash:  serverHash,
                kdfParams:     kdfParams,
                salt:          salt,
                stretchedKeys: stretched,
                deviceId:      deviceId
            )
            stretchedHandedOver = true
            logger.info("2FA required")
            return .requiresTwoFactor(twoFactorMethod(from: providers))
        }

        // Step 6: Finalize the session with the token response.
        logger.info("Step 6: finalizing session")
        if DebugConfig.isEnabled {
            logger.debug("[debug] token response fields present → key=\(tokenResp.key != nil, privacy: .public) kdf=\(tokenResp.kdfSettings != nil, privacy: .public) userId=\(tokenResp.userId != nil, privacy: .public) email=\(tokenResp.email != nil, privacy: .public) refreshToken=\(tokenResp.refreshToken != nil, privacy: .public)")
        }
        let account = try await finalizeSession(
            tokenResp:    tokenResp,
            stretched:    stretched,
            kdf:          kdfParams,
            salt:         salt,
            environment:  env,
            startedAt:    epoch
        )
        logger.info("Login succeeded")
        return .success(account)
    }

    func loginWithTOTP(code: String, rememberDevice: Bool) async throws -> Account {
        logger.info("Submitting TOTP code")
        let epoch = lockEpoch
        // Read the fields, not the whole struct: a local copy of it would share the key buffers
        // and keep clearPendingTwoFactor() from zeroing them in place.
        guard let email        = pendingTwoFactor?.email,
              let passwordHash = pendingTwoFactor?.passwordHash,
              let deviceId     = pendingTwoFactor?.deviceId,
              let env          = serverEnvironment else {
            throw AuthError.invalidCredentials
        }

        let tokenResp: TokenResponse
        do {
            tokenResp = try await apiClient.identityToken(
                email:             email,
                passwordHash:      passwordHash,
                deviceIdentifier:  deviceId,
                twoFactorToken:    code,
                twoFactorProvider: 0,   // authenticatorApp
                twoFactorRemember: rememberDevice
            )
        } catch let err as IdentityTokenError {
            switch err {
            case .twoFactorCodeInvalid:
                logger.error("Login failed: \(AuthError.invalidTwoFactorCode.localizedDescription, privacy: .public)")
                throw AuthError.invalidTwoFactorCode
            case .invalidCredentials:
                logger.error("Login failed: \(AuthError.invalidTwoFactorCode.localizedDescription, privacy: .public)")
                throw AuthError.invalidTwoFactorCode   // TOTP wrong code maps to same user-visible error
            case .twoFactorRequired:
                logger.error("Login failed: \(AuthError.invalidTwoFactorCode.localizedDescription, privacy: .public)")
                throw AuthError.invalidTwoFactorCode
            }
        }

        logger.info("TOTP accepted")
        // The two-factor step ends here, whether the session can be finalized or not. The keys
        // move out of the stored struct into this local, its only owner, so a cancel or sign-out
        // during the await below finds nothing to zero and cannot zero a mere copy.
        guard var stretched = pendingTwoFactor?.stretchedKeys,
              let kdf  = pendingTwoFactor?.kdfParams,
              let salt = pendingTwoFactor?.salt else { throw AuthError.invalidCredentials }
        pendingTwoFactor = nil
        defer {
            zero(&stretched.encryptionKey, "pendingEncryptionKey")
            zero(&stretched.macKey, "pendingMacKey")
        }
        return try await finalizeSession(tokenResp: tokenResp, stretched: stretched, kdf: kdf,
                                         salt: salt, environment: env, startedAt: epoch)
    }

    // MARK: - Unlock

    func cancelTwoFactor() {
        // Note: passwordHash (String) cannot be zeroed — String storage is immutable.
        clearPendingTwoFactor()
        logger.info("Pending 2FA state cleared — stretched keys zeroed")
    }

    func unlockWithPassword(_ masterPassword: Data) async throws -> Account {
        logger.info("Unlock attempt")
        let epoch = lockEpoch
        let userId: String
        do {
            userId = try readString(key: KeychainKey.activeUserId)
        } catch {
            logger.error("No active user ID in Keychain: \(ErrorLog.describe(error), privacy: .public)")
            throw AuthError.invalidCredentials
        }

        // Read account data (email, name, serverEnvironment) once via account(for:).
        // Previously email was also read directly below for use in makeMasterKey, producing
        // a duplicate read. Now account(for:) is called first and email is reused from it.
        let restoredAccount: Account
        do {
            restoredAccount = try account(for: userId)
        } catch {
            logger.error("Missing session data in Keychain: \(ErrorLog.describe(error), privacy: .public)")
            throw AuthError.invalidCredentials
        }

        let kdfKey    = KeychainKey.user(userId, "kdfParams")
        let encKeyKey = KeychainKey.user(userId, "encUserKey")

        let kdfJSON: String
        let encUserKey: String
        do {
            kdfJSON    = try readString(key: kdfKey)
            encUserKey = try readString(key: encKeyKey)
        } catch {
            logger.error("Missing session data in Keychain: \(ErrorLog.describe(error), privacy: .public)")
            throw AuthError.invalidCredentials
        }

        guard let kdfData = kdfJSON.data(using: .utf8) else {
            logger.error("KDF params not valid UTF-8")
            throw AuthError.invalidCredentials
        }
        let kdfParams: KdfParams
        do {
            kdfParams = try JSONDecoder().decode(KdfParams.self, from: kdfData)
        } catch {
            logger.error("KDF params decode failed: \(ErrorLog.describe(error), privacy: .public)")
            throw AuthError.invalidCredentials
        }

        // The salt that worked at login; installs from before fix-kdf-derivation-and-validation
        // stored none, and their salt is the email (D3).
        // Only a missing entry falls back: deriving from the wrong salt after a Keychain failure
        // would look like a wrong password.
        let storedSalt: String?
        do {
            storedSalt = try readString(key: KeychainKey.user(userId, "masterPasswordSalt"))
        } catch KeychainError.itemNotFound {
            storedSalt = nil
        } catch {
            logger.error("Stored salt unreadable in Keychain: \(ErrorLog.describe(error), privacy: .public)")
            throw AuthError.invalidCredentials
        }
        let salt = storedSalt ?? Self.normalized(restoredAccount.email)

        if DebugConfig.isEnabled {
            logger.debug("[debug] unlock: KDF type=\(String(describing: kdfParams.type), privacy: .public) storedSalt=\(storedSalt != nil, privacy: .public) encUserKey prefix=\(String(encUserKey.prefix(2)), privacy: .public)")
        }
        // `masterPassword` is already `Data`; pass directly to KDF (Constitution §III). The stored
        // settings are checked again there, so a weakened Keychain entry is refused too (D2).
        var masterKey  = try await deriveMasterKey(password: masterPassword, salt: salt, kdf: kdfParams)
        defer { zero(&masterKey, "masterKey") }
        var stretched  = try await crypto.stretchKey(masterKey: masterKey)
        defer {
            zero(&stretched.encryptionKey, "stretchedEncryptionKey")
            zero(&stretched.macKey, "stretchedMacKey")
        }
        var vaultKeys  = try await crypto.decryptSymmetricKey(
            encUserKey:    encUserKey,
            stretchedKeys: stretched
        )
        try await loadVaultKeys(&vaultKeys, startedAt: epoch)

        // Restore API client state so the post-unlock sync can make authenticated requests.
        // Both baseURL and accessToken are nil on a fresh app launch until restored here.
        serverEnvironment = restoredAccount.serverEnvironment
        await apiClient.setBaseURL(restoredAccount.serverEnvironment.base)

        if let accessToken = try? readString(key: KeychainKey.user(userId, "accessToken")) {
            await apiClient.setAccessToken(accessToken)
            if DebugConfig.isEnabled {
                logger.debug("[debug] unlock: baseURL and access token restored to API client")
            }

            // The stored access token may be expired. Attempt a refresh using the stored
            // refresh token so the post-unlock sync doesn't fail with 401.
            let refreshTokenOpt = try? readString(key: KeychainKey.user(userId, "refreshToken"))
            if refreshTokenOpt == nil {
                logger.debug("Unlock: no refresh token in Keychain — skipping token refresh")
            }
            if let refreshToken = refreshTokenOpt {
                do {
                    let tokens = try await apiClient.refreshAccessToken(refreshToken: refreshToken)
                    do {
                        try writeString(tokens.accessToken, key: KeychainKey.user(userId, "accessToken"))
                        if let newRefresh = tokens.refreshToken {
                            try writeString(newRefresh, key: KeychainKey.user(userId, "refreshToken"))
                        }
                    } catch {
                        // Persisting the refreshed token failed — the next launch will use
                        // the old (expired) token and the user may be signed out unexpectedly.
                        logger.error("Unlock: failed to persist refreshed tokens — next launch may require re-auth: \(ErrorLog.describe(error), privacy: .public)")
                    }
                    if DebugConfig.isEnabled {
                        logger.debug("[debug] unlock: access token refreshed successfully")
                    }
                } catch {
                    // Refresh failed — keep the old token; sync will fail with 401 (non-fatal).
                    logger.warning("Unlock: token refresh failed — sync may fail: \(ErrorLog.describe(error), privacy: .public)")
                }
            }
        } else {
            logger.error("Unlock: access token not found in Keychain — sync will fail with 401")
        }

        logger.info("Unlock succeeded")
        await MainActor.run {
            NotificationCenter.default.post(name: .vaultDidUnlock, object: nil)
        }
        return restoredAccount
    }

    // MARK: - Session

    func storedAccount() -> Account? {
        guard let userId = try? readString(key: KeychainKey.activeUserId) else {
            logger.debug("No stored account — activeUserId not found")
            return nil
        }
        do {
            return try account(for: userId)
        } catch {
            logger.error("Failed to reconstruct account for stored userId: \(ErrorLog.describe(error), privacy: .public)")
            return nil
        }
    }

    func signOut() async throws {
        logger.info("Signing out — clearing session data")
        lockEpoch &+= 1
        let userId: String
        do {
            userId = try readString(key: KeychainKey.activeUserId)
        } catch {
            logger.debug("No active userId during sign-out (may already be cleared)")
            userId = ""
        }

        // Clear biometric Keychain item and preference before clearing other keys.
        try? await disableBiometricUnlock()

        // Clear per-user keys first — best-effort, log failures.
        if !userId.isEmpty {
            for suffix in ["accessToken", "refreshToken", "encUserKey", "kdfParams", "masterPasswordSalt",
                           "email", "name", "serverEnvironment"] {
                do {
                    try keychain.delete(key: KeychainKey.user(userId, suffix))
                } catch {
                    logger.debug("Keychain delete \(suffix) skipped: \(ErrorLog.describe(error), privacy: .public)")
                }
            }
        }
        // Clear global key last.
        do {
            try keychain.delete(key: KeychainKey.activeUserId)
        } catch {
            logger.debug("activeUserId delete skipped: \(ErrorLog.describe(error), privacy: .public)")
        }

        // Use self.lockVault() rather than crypto.lockVault() directly so that the
        // .vaultDidLock notification is posted — ItemEditViewModel observes it to
        // dismiss any open edit sheet and clear the plaintext DraftVaultItem (§III).
        await lockVault()

        // Clear the bearer token from the API client's memory so it cannot be read
        // from a heap dump after sign-out (Constitution §III).
        await apiClient.clearAccessToken()

        serverEnvironment = nil
        clearPendingTwoFactor()
    }

    // MARK: - Lock

    var isVaultUnlocked: Bool {
        get async { await crypto.isUnlocked }
    }

    /// Zeroes and drops all key material: the vault key, every per-item key and every org key.
    /// The one teardown path; `signOut()` calls it too.
    func lockVault() async {
        lockEpoch &+= 1
        // A two-factor step does not survive a lock either; its keys are zeroed now.
        clearPendingTwoFactor()
        await crypto.lockVault()
        await vaultKeyCache.clear()
        await orgKeyCache.clear()
        // Notify any open edit sheets to dismiss immediately (no confirmation prompt).
        // Posted on the main queue because subscribers are @MainActor UI components.
        await MainActor.run {
            NotificationCenter.default.post(name: .vaultDidLock, object: nil)
        }
    }

    // MARK: - Biometric unlock

    var deviceBiometricCapable: Bool {
        var error: NSError?
        let capable = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        logBiometricAvailabilityFailure(error)
        return capable
    }

    var biometricUnlockAvailable: Bool {
        // Fast synchronous check for UI binding (design Decision 5).
        // Actual Keychain item existence is verified only inside unlockWithBiometrics().
        guard defaults.bool(forKey: BiometricPreferenceKey.unlockEnabled) else { return false }
        var error: NSError?
        let available = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        logBiometricAvailabilityFailure(error)
        return available
    }

    /// Logs the `NSError` discarded by `canEvaluatePolicy` so the reason biometrics are
    /// considered unavailable is diagnosable (#67), instead of collapsing it to a bare
    /// `Bool`. Skips the routine device states (no hardware, no enrollment, no passcode
    /// set) — those are normal, not failures, and would otherwise log on every render.
    private func logBiometricAvailabilityFailure(_ error: NSError?) {
        guard let error else { return }
        if let laError = error as? LAError {
            switch laError.code {
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                return
            default:
                break
            }
        }
        logger.error("Biometric availability check failed: \(ErrorLog.describe(error), privacy: .public)")
    }

    func enableBiometricUnlock() async throws {
        // Guard: vault must be unlocked — keys must be in memory (spec requirement).
        guard await crypto.isUnlocked else {
            throw AuthError.biometricUnavailable
        }
        let keys = try await crypto.currentKeys()
        var data = keys.toData()
        defer { data.resetBytes(in: data.indices) }
        guard let userId = try? readString(key: KeychainKey.activeUserId) else {
            throw AuthError.biometricUnavailable
        }
        try biometricKeychain.writeBiometric(
            data: data,
            key: KeychainKey.biometricVaultKey(userId)
        )
        defaults.set(true, forKey: BiometricPreferenceKey.unlockEnabled)
        logger.info("Biometric unlock enabled")
    }

    func disableBiometricUnlock() async throws {
        if let userId = try? readString(key: KeychainKey.activeUserId) {
            try? biometricKeychain.deleteBiometric(key: KeychainKey.biometricVaultKey(userId))
        }
        defaults.set(false, forKey: BiometricPreferenceKey.unlockEnabled)
        logger.info("Biometric unlock disabled")
    }

    func unlockWithBiometrics() async throws -> Account {
        logger.info("Biometric unlock attempt")
        let epoch = lockEpoch
        guard let userId = try? readString(key: KeychainKey.activeUserId) else {
            throw AuthError.biometricUnavailable
        }

        let restoredAccount: Account
        do {
            restoredAccount = try account(for: userId)
        } catch {
            logger.error("Missing session data for biometric unlock: \(ErrorLog.describe(error), privacy: .public)")
            throw AuthError.biometricUnavailable
        }

        // Read the biometric Keychain item — evaluatePolicy runs inside readBiometric,
        // producing the inline Touch ID prompt (no security-agent modal).
        var keyData: Data
        do {
            keyData = try await biometricKeychain.readBiometric(
                key: KeychainKey.biometricVaultKey(userId)
            )
        } catch let error as KeychainError where error == .itemNotFound {
            // Keychain item deleted externally (Keychain Access, reinstall, etc.) —
            // NOT a fingerprint-change. Degrade silently: clear the flag and reset
            // the enrollment gate so re-enrollment is offered after next password unlock.
            // UnlockViewModel must NOT show an error for this case (spec §degradation).
            defaults.set(false, forKey: BiometricPreferenceKey.unlockEnabled)
            defaults.set(false, forKey: BiometricPreferenceKey.enrollmentPromptShown)
            throw AuthError.biometricItemNotFound
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel:
                // User cancelled — rethrow as errSecUserCanceled so UnlockViewModel re-arms.
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled))
            default:
                // Lockout or other LAError — surface error without clearing stored key.
                throw laError
            }
        } catch {
            // Legacy OSStatus errors from SecItemCopyMatching (e.g. .biometryCurrentSet
            // invalidation that surfaces as errSecAuthFailed on some OS versions).
            let nsError = error as NSError
            if nsError.domain == NSOSStatusErrorDomain {
                let status = OSStatus(nsError.code)
                if status == errSecUserCanceled || status == errSecAuthFailed {
                    throw error
                }
            }
            defaults.set(false, forKey: BiometricPreferenceKey.unlockEnabled)
            defaults.set(false, forKey: BiometricPreferenceKey.enrollmentPromptShown)
            throw AuthError.biometricInvalidated
        }

        // Deserialize CryptoKeys from the 64-byte blob (design Decision 1).
        // The keys get their own buffers; the 64-byte blob read from the keychain is zeroed.
        defer { keyData.resetBytes(in: keyData.indices) }
        guard var vaultKeys = CryptoKeys(data: keyData) else {
            logger.error("Biometric Keychain item has invalid format")
            throw AuthError.biometricUnavailable
        }

        try await loadVaultKeys(&vaultKeys, startedAt: epoch)

        // Restore API client state — same as unlockWithPassword().
        serverEnvironment = restoredAccount.serverEnvironment
        await apiClient.setBaseURL(restoredAccount.serverEnvironment.base)

        if let accessToken = try? readString(key: KeychainKey.user(userId, "accessToken")) {
            await apiClient.setAccessToken(accessToken)

            if let refreshToken = try? readString(key: KeychainKey.user(userId, "refreshToken")) {
                do {
                    let tokens = try await apiClient.refreshAccessToken(refreshToken: refreshToken)
                    try? writeString(tokens.accessToken, key: KeychainKey.user(userId, "accessToken"))
                    if let newRefresh = tokens.refreshToken {
                        try? writeString(newRefresh, key: KeychainKey.user(userId, "refreshToken"))
                    }
                } catch {
                    logger.warning("Biometric unlock: token refresh failed — sync may fail: \(ErrorLog.describe(error), privacy: .public)")
                }
            }
        }

        logger.info("Biometric unlock succeeded")
        await MainActor.run {
            NotificationCenter.default.post(name: .vaultDidUnlock, object: nil)
        }
        return restoredAccount
    }

    // MARK: - EmbeddedBiometricUnlock

    /// Evaluates biometric policy on `context` then reads the vault key and unlocks.
    /// If `LAAuthenticationView` was paired with `context` before this call (via
    /// `EmbeddedTouchIDView`), `evaluatePolicy` routes inline — no modal appears.
    func unlockWithBiometrics(context: LAContext) async throws -> Account {
        logger.info("Embedded biometric unlock attempt")
        let epoch = lockEpoch
        guard let userId = try? readString(key: KeychainKey.activeUserId) else {
            throw AuthError.biometricUnavailable
        }

        let restoredAccount: Account
        do {
            restoredAccount = try account(for: userId)
        } catch {
            logger.error("Missing session data for embedded biometric unlock: \(ErrorLog.describe(error), privacy: .public)")
            throw AuthError.biometricUnavailable
        }

        // readBiometric(key:context:) calls evaluatePolicy on the provided context.
        // Because LAAuthenticationView is paired with it, no modal appears.
        var keyData: Data
        do {
            keyData = try await biometricKeychain.readBiometric(
                key: KeychainKey.biometricVaultKey(userId),
                context: context
            )
        } catch let error as KeychainError where error == .itemNotFound {
            // Same silent-degradation path as the non-embedded overload above.
            defaults.set(false, forKey: BiometricPreferenceKey.unlockEnabled)
            defaults.set(false, forKey: BiometricPreferenceKey.enrollmentPromptShown)
            throw AuthError.biometricItemNotFound
        } catch {
            // Let LAError (cancel, lockout) propagate — caller handles re-arming.
            throw error
        }

        // The keys get their own buffers; the 64-byte blob read from the keychain is zeroed.
        defer { keyData.resetBytes(in: keyData.indices) }
        guard var vaultKeys = CryptoKeys(data: keyData) else {
            logger.error("Embedded biometric Keychain item has invalid format")
            throw AuthError.biometricUnavailable
        }

        try await loadVaultKeys(&vaultKeys, startedAt: epoch)
        serverEnvironment = restoredAccount.serverEnvironment
        await apiClient.setBaseURL(restoredAccount.serverEnvironment.base)

        if let accessToken = try? readString(key: KeychainKey.user(userId, "accessToken")) {
            await apiClient.setAccessToken(accessToken)
            if let refreshToken = try? readString(key: KeychainKey.user(userId, "refreshToken")) {
                do {
                    let tokens = try await apiClient.refreshAccessToken(refreshToken: refreshToken)
                    try? writeString(tokens.accessToken, key: KeychainKey.user(userId, "accessToken"))
                    if let newRefresh = tokens.refreshToken {
                        try? writeString(newRefresh, key: KeychainKey.user(userId, "refreshToken"))
                    }
                } catch {
                    logger.warning("Embedded biometric: token refresh failed: \(ErrorLog.describe(error), privacy: .public)")
                }
            }
        }

        logger.info("Embedded biometric unlock succeeded")
        await MainActor.run {
            NotificationCenter.default.post(name: .vaultDidUnlock, object: nil)
        }
        return restoredAccount
    }

    // MARK: - Private helpers

    /// Completes a successful token exchange: decrypts vault key, stores credentials, returns Account.
    ///
    /// - Parameters:
    ///   - kdf, salt: the settings and salt the master key was derived with. They just decrypted the
    ///     user key, so they are the ones stored for unlock, not the token response's (D6).
    private func finalizeSession(
        tokenResp:   TokenResponse,
        stretched:   CryptoKeys,
        kdf:         KdfParams,
        salt:        String,
        environment: ServerEnvironment,
        startedAt epoch: Int
    ) async throws -> Account {
        // Vaultwarden omits UserId/Email from the token response body (unlike the official
        // Bitwarden server, which includes them as PascalCase fields). Extract identity from
        // JWT claims instead: sub → userId, email → email, name → display name.
        // Trust model: the JWT was just issued by the user's own configured server over HTTPS
        // and is only used to read their own identity — not to make authorization decisions.
        // A malicious server could falsify these claims, but trusting the chosen server is
        // an explicit prerequisite of self-hosting. Signature verification is skipped for
        // this reason — see decodeJWTClaims for the full rationale.
        let jwtClaims = decodeJWTClaims(tokenResp.accessToken)
        let userId = tokenResp.userId ?? jwtClaims["sub"] as? String
        let email  = tokenResp.email  ?? jwtClaims["email"] as? String
        let name   = tokenResp.name   ?? jwtClaims["name"] as? String

        if DebugConfig.isEnabled {
            let jwtKeys = jwtClaims.keys.sorted().joined(separator: ", ")
            logger.debug("[debug] finalizeSession: body userId=\(tokenResp.userId != nil, privacy: .public) email=\(tokenResp.email != nil, privacy: .public) | JWT claims: [\(jwtKeys, privacy: .public)] | resolved userId=\(userId != nil, privacy: .public) email=\(email != nil, privacy: .public)")
        }

        guard let userId,
              let email,
              let encKey       = tokenResp.key,
              let accessToken  = tokenResp.accessToken.isEmpty ? nil : tokenResp.accessToken,
              let refreshToken = tokenResp.refreshToken else {
            logger.error("finalizeSession: missing required fields — userId=\(userId != nil, privacy: .public) email=\(email != nil, privacy: .public) key=\(tokenResp.key != nil, privacy: .public) accessTokenNonEmpty=\(!tokenResp.accessToken.isEmpty, privacy: .public) refreshToken=\(tokenResp.refreshToken != nil, privacy: .public)")
            throw AuthError.invalidCredentials
        }
        logger.info("Session finalized for user \(userId, privacy: .private)")

        // Decrypt the encrypted user key using the stretched master keys.
        if DebugConfig.isEnabled {
            logger.debug("[debug] decrypting encUserKey (type prefix: \(String(encKey.prefix(2)), privacy: .public))")
        }
        var vaultKeys = try await crypto.decryptSymmetricKey(
            encUserKey:    encKey,
            stretchedKeys: stretched
        )
        if DebugConfig.isEnabled {
            logger.debug("[debug] vault keys decrypted — encKey=\(vaultKeys.encryptionKey.count, privacy: .public) bytes, macKey=\(vaultKeys.macKey.count, privacy: .public) bytes")
        }
        try await loadVaultKeys(&vaultKeys, startedAt: epoch)

        // Persist session data in Keychain.
        try writeString(userId,       key: KeychainKey.activeUserId)
        try writeString(accessToken,  key: KeychainKey.user(userId, "accessToken"))
        try writeString(refreshToken, key: KeychainKey.user(userId, "refreshToken"))
        try writeString(encKey,       key: KeychainKey.user(userId, "encUserKey"))
        try writeString(email,        key: KeychainKey.user(userId, "email"))
        if let name {
            try writeString(name,     key: KeychainKey.user(userId, "name"))
        }

        // Persist the KDF settings and salt that decrypted the user key, for offline unlock (D6).
        if let reported = tokenResp.masterPasswordUnlock?.kdf, reported.kdfParams != kdf {
            logger.error("Token response reports other KDF settings than prelogin; storing the ones that worked")
        }
        let kdfJSON = try JSONEncoder().encode(kdf)
        try keychain.write(data: kdfJSON, key: KeychainKey.user(userId, "kdfParams"))
        try writeString(salt, key: KeychainKey.user(userId, "masterPasswordSalt"))

        // Persist server environment for unlock.
        let envJSON = try JSONEncoder().encode(environment)
        try keychain.write(data: envJSON, key: KeychainKey.user(userId, "serverEnvironment"))

        await apiClient.setAccessToken(accessToken)

        return Account(
            userId:            userId,
            email:             email,
            name:              name,
            serverEnvironment: environment
        )
    }

    /// Reconstructs an `Account` from Keychain data for a known `userId`.
    private func account(for userId: String) throws -> Account {
        let email = try readString(key: KeychainKey.user(userId, "email"))
        let name  = try? readString(key: KeychainKey.user(userId, "name"))
        let envData = try keychain.read(key: KeychainKey.user(userId, "serverEnvironment"))

        let env: ServerEnvironment
        do {
            env = try JSONDecoder().decode(ServerEnvironment.self, from: envData)
        } catch {
            logger.error("Server environment decode failed: \(ErrorLog.describe(error), privacy: .public)")
            throw AuthError.invalidCredentials
        }
        return Account(userId: userId, email: email, name: name, serverEnvironment: env)
    }

    /// Returns the persisted device identifier UUID, generating and storing one on first use.
    ///
    /// Per Bitwarden device registration requirements, each installation should present a
    /// stable UUID. Stored under `bw.macos:deviceIdentifier` (not per-user; shared across accounts).
    private func deviceIdentifier() throws -> String {
        do {
            return try readString(key: KeychainKey.deviceIdentifier)
        } catch {
            logger.debug("No device identifier — generating new UUID")
        }
        let newId = UUID().uuidString
        try writeString(newId, key: KeychainKey.deviceIdentifier)
        return newId
    }

    /// Reads a UTF-8 string from the Keychain.
    private func readString(key: String) throws -> String {
        let data = try keychain.read(key: key)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AuthError.invalidCredentials
        }
        return string
    }

    /// Writes a UTF-8 string to the Keychain.
    private func writeString(_ value: String, key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw AuthError.invalidCredentials
        }
        try keychain.write(data: data, key: key)
    }

    /// Decodes the payload of a JWT access token without verifying the signature.
    ///
    /// Vaultwarden does not return `UserId` or `Email` in the token response body —
    /// they are present as standard JWT claims (`sub` = userId, `email` = email, `name` = name).
    ///
    /// - Security goal: extract the user's own identity fields from a freshly-issued token.
    /// - Why signature skip is safe: the token arrived over HTTPS from our configured server
    ///   moments ago and is only used to read `sub`/`email`/`name` for local Keychain storage.
    ///   It is never used for access-control or authorization decisions.
    /// - What this does NOT protect against: a compromised or malicious self-hosted server.
    ///   If the server issues a JWT with a falsified `sub`, we would store the wrong userId.
    ///   Defending against a malicious server is out of scope — the user chose to trust it.
    /// - Base64url decoding per RFC 7519 §3 (JWT compact serialization: header.payload.signature).
    ///
    /// - Parameter jwt: A dot-separated JWT string (`header.payload.signature`).
    /// - Returns: Decoded payload as a `[String: Any]` dictionary, or empty on failure.
    private func decodeJWTClaims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Add padding if needed (JWT uses unpadded base64url).
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to decode JWT payload")
            return [:]
        }
        return json
    }

    /// Trimmed and lowercased, as the Bitwarden SDK (`kdf.rs` `derive`) and the TS clients
    /// (`email.trim().toLowerCase()`) do (fix-kdf-derivation-and-validation, D3).
    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Derives the master key, mapping a refused KDF setting to the error the user sees. Nothing is
    /// derived and nothing is sent to `/connect/token` when the settings are refused (D2).
    private func deriveMasterKey(password: Data, salt: String, kdf: KdfParams) async throws -> Data {
        do {
            return try await crypto.makeMasterKey(password: password, salt: salt, kdf: kdf)
        } catch PrizmCryptoServiceError.insufficientKdfParameters {
            logger.error("Refused: KDF settings below the minimums")
            throw AuthError.kdfSettingsTooWeak
        } catch PrizmCryptoServiceError.invalidKdfParameters {
            logger.error("Refused: unusable KDF settings")
            throw AuthError.invalidKdfSettings
        }
    }

    /// Maps a list of Bitwarden 2FA provider type numbers to a `TwoFactorMethod`.
    ///
    /// Only TOTP (provider 0) is supported in v1.  Any other combination returns `.unsupported`.
    private func twoFactorMethod(from providers: [Int]) -> TwoFactorMethod {
        if providers.contains(0) { return .authenticatorApp }
        let names = providers.map { String($0) }.joined(separator: ", ")
        return .unsupported(name: names)
    }
}

// MARK: - Keychain key namespacing

/// Centralised Keychain key factory.
///
/// Key format:
///   - Global:    `bw.macos:<name>`
///   - Per-user:  `bw.macos:<userId>:<name>`
enum KeychainKey {
    static let activeUserId    = "bw.macos:activeUserId"
    static let deviceIdentifier = "bw.macos:deviceIdentifier"

    static func user(_ userId: String, _ name: String) -> String {
        "bw.macos:\(userId):\(name)"
    }

    /// Per-user biometric vault key — stored via `BiometricKeychainServiceImpl`
    /// behind `.biometryCurrentSet` access control (design Decision 1).
    static func biometricVaultKey(_ userId: String) -> String {
        "bw.macos:\(userId):biometricVaultKey"
    }
}
