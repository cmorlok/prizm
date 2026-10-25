# Design

## Context

### Official behaviour

- **Org keys follow each sync.** `KeyService.setOrgKeys` replaces the whole map of encrypted org
  keys with the orgs in the latest sync response
  (`clients/libs/key-management/src/key.service.ts:123-147`). Ciphers whose org key is missing are
  excluded before decryption, with the comment "Fixes a bug causing decryption failures
  immediately after a user leaves an organization"
  (`clients/libs/common/src/vault/services/cipher.service.ts:1550-1554`).
- **Zeroing in the SDK.** KDF output is held in a pinned box and the intermediate hash is zeroized
  (`sdk-internal/crates/bitwarden-crypto/src/keys/kdf.rs:43-47`). After Argon2 the SDK calls
  `clear_stack()` because Argon2 leaves key material on the stack (`kdf.rs:74-77`).
  `EncString` is `ZeroizeOnDrop` (`enc_string/symmetric.rs:68`).
- **Device identifier.** Kept across logouts: stored under the global key `global_applicationId_appId`
  (`clients/libs/common/src/platform/services/app-id.service.ts:6`).
- **Biometric storage.**
  - iOS: user key in a keychain item with `.biometryCurrentSet`
    (`ios/BitwardenShared/Core/Auth/Services/KeychainRepository.swift:66-90`).
  - Desktop macOS: user key in the login keychain without a biometric access control, behind an
    in-app Touch ID prompt
    (`clients/apps/desktop/src/key-management/biometrics/os-biometrics-mac.service.ts:24-58`:
    `passwords.setPassword` / `getPassword`, `systemPreferences.promptTouchID`).

### Prizm today

- `PrizmApp.signOut()` (`Prizm/App/PrizmApp.swift:458-470`): `authRepo.signOut()`,
  `vaultRepo.clearVault()`, `vaultKeyCache.clear()`. No `orgKeyCache.clear()`.
- `PrizmApp.lockVault()` (`:477-494`) clears `vaultKeyCache` and `orgKeyCache` itself.
- `UnlockViewModel.signInWithDifferentAccount()` (`Prizm/Presentation/Unlock/UnlockViewModel.swift:216-226`)
  calls only `auth.signOut()`.
- `AuthRepositoryImpl.signOut()` (`Prizm/Data/Repositories/AuthRepositoryImpl.swift:384-426`)
  deletes Keychain items, calls `lockVault()` (which zeroes the vault key in
  `PrizmCryptoServiceImpl.lockVault`, `PrizmCryptoService.swift:243-257`), clears the access token,
  and sets `pendingTwoFactor = nil` without zeroing (`:425`). The device identifier is kept
  (`:399-400` lists the deleted items).
- `AuthRepositoryImpl` has no reference to either cache (`Prizm/App/AppContainer.swift:80-85`).
- `OrgKeyCache.clear()` zeroes each key in place (`Prizm/Data/Crypto/OrgKeyCache.swift:55-69`).
- Sync (`Prizm/Data/Repositories/SyncRepositoryImpl.swift:133-160`): `orgKeyCache.clear()` is
  called inside `if !syncResponse.organizations.isEmpty, let encPrivateKey = …`, after the private
  key decrypted.
- Login (`AuthRepositoryImpl.swift:105-121`) and unlock (`:306-318`): `masterKey` and `stretched` are
  `let`; never zeroed. `cancelTwoFactor()` (`:238-256`) zeroes the pending stretched keys in place;
  TOTP success (`:227`) and sign-out (`:425`) do not.
- `decryptSymmetricKey` (`PrizmCryptoService.swift:409-437`) returns `CryptoKeys` built from
  slices of `keyData`, so the vault key shares `keyData`'s buffer.
- `Argon2Swift.hashPasswordBytes` (`LocalPackages/Argon2Swift/Sources/Swift/Argon2Swift.swift:64-94`)
  copies the hash out, then `freePtr` (`:175-179`) deinitializes and deallocates `hash` and
  `encoded` without overwriting them. `encoded` contains the hash in base64.
- Debug logging: `identityToken` logs all parameters except `password` with `privacy: .public`
  (`Prizm/Data/Network/PrizmAPIClient.swift:472-479`); the non-JSON 400 body prefix is `.public`
  (`:531`). `DebugConfig` is enabled by `--debug-mode` (`Prizm/App/Config.swift:30-41`).
- SECURITY.md: master key "zeroed on lock or sign-out" (`:72`); stretched keys "zeroed on lock"
  (`:73`); device identifier "deleted on sign-out" (`:82`); "Sign out — all in-memory key material
  is zeroed" (`:98`).

## Goals / Non-Goals

**Goals**
- After sign-out, no key of the previous account is reachable from Prizm's own objects.
- Org keys in memory always match the latest sync.
- Each transient key buffer that Prizm owns is zeroed on every exit path.
- Debug logs contain no email, 2FA code or token as public data.
- SECURITY.md describes what the code does.

**Non-Goals:** see proposal.md.

## Decisions

### D1. One teardown in the Data layer

`AuthRepositoryImpl` gets `VaultKeyCache` and `OrgKeyCache` injected. Its `lockVault()` zeroes the
vault key (as today), then clears both caches, then posts `.vaultDidLock`. `signOut()` already
calls `lockVault()`, so sign-out and "sign in with a different account" are covered.
`PrizmApp.signOut()` and `PrizmApp.lockVault()` stop clearing caches themselves.

**Rejected:** add `orgKeyCache.clear()` to `PrizmApp.signOut()`. It fixes C-13 but leaves three
call sites that must stay in sync, which is how the bug arose.

### D2. Sync replaces org keys (reconciled with `fix-org-key-required-on-write`)

That change already swaps the org keys in one step (`OrgKeyCache.replaceAll`) and replaces them with
an empty map when the response has no organizations or no private key. Clearing at the start of the
sync, as first planned here, would reopen the empty window it closed, so it is not done.

This change adds the remaining case: when the org step fails (the private key does not decrypt),
the sync still completes without org items, so the cache is replaced with an empty map too. Only a
sync that fails as a whole keeps the previous keys, together with the previous items. Snapshots
taken by an in-flight mapping keep their own copy until they finish (documented in SECURITY.md).

### D3. Zero what Prizm owns, on every path

- Login and unlock: `masterKey` and `stretched` become `var`, zeroed in `defer`. On the 2FA path the
  stretched keys move into `pendingTwoFactor` and the local copy is released without zeroing,
  because zeroing it would copy the shared buffer and leave the original untouched.
- One `clearPendingTwoFactor()` zeroes in place and sets `nil`. It is used by cancel, TOTP success,
  TOTP failure that ends the attempt, and sign-out.
- `decryptSymmetricKey`: copy the two halves into fresh `Data`, then zero `keyData`.
- Argon2Swift: overwrite `hash` and `encoded` with zeros (`memset_s` or
  `withMemoryRebound` + `initialize(repeating: 0)`) before `deallocate`. The resulting `[UInt8]`
  copies in `Argon2SwiftResult` are zeroed by `argon2idDerive` after it builds the `Data`.
  The vendored package's version suffix is bumped (today `1.0.1-bw2`, commit `d0f361e`) and the
  patch is noted in its header.

Tests use test seams that expose the owner's buffer, as `OrgKeyCryptoKATTests.swift:47` already
does for `OrgKeyCache`.

**Rejected:** a `SecureBytes` wrapper type with `mlock` and zero-on-deinit. Cleaner, but touches
every key consumer. Worth a separate change if the maintainer wants it.

### D4. Allow-list for debug logs

`identityToken` logs only `grant_type`, `scope`, `client_id`, `deviceType`, `twoFactorProvider` and
`twoFactorRemember` as `.public`. `username`, `twoFactorToken`, `deviceIdentifier` and `password`
are not logged at all. The non-JSON 400 body is logged `.private`. The logged string is built by
a pure function, `debugDescription(ofTokenParams:)`, so a unit test can check it; `os.Logger`
output itself cannot be captured in XCTest.

**Rejected:** keep a deny-list (`password` only). New parameters would be logged by default.

### D5. Documentation

- SECURITY.md key table: master key and stretched keys "zeroed right after use (login, unlock)";
  pending-2FA keys "zeroed when the 2FA step ends"; org keys "zeroed and cleared on lock, sign-out
  and every sync"; RSA private key "zeroed right after the org keys are unwrapped" (stronger than
  today's text); device identifier "kept on sign-out, as in official clients".
- A short paragraph on Swift's limits: copy-on-write copies and buffers inside system frameworks
  cannot be zeroed.
- Biometric section: "iOS uses the same model. The Bitwarden desktop app on macOS stores the user
  key in the login keychain without a biometric access control and asks for Touch ID in the app.
  The keychain item is protected by an access control evaluated with the Secure Enclave; the key
  itself is not stored in the Secure Enclave." The archived design under
  `openspec/changes/archive/` is left as a historical record.
- `Config.swift` and `OrgKeyCache.swift` comments match the code.

## Risks / Trade-offs

- **[Low] Org keys after a failed org step** are dropped; org items stay hidden until the next good
  sync. → Same as official clients; the sync status already shows the failure.
- **[Low] Zeroing a shared buffer** zeroes a live key by mistake. → D3 copies first; tests check
  that the vault still decrypts after login and unlock.
- **[Low] Editing the vendored Argon2Swift.** → A two-line change with a note and a test that
  the output is unchanged (KATs from `fix-kdf-derivation-and-validation`).

## Open Questions

1. Should Prizm adopt a dedicated secure-buffer type for all key material (D3, rejected
   alternative)? Out of scope here.
