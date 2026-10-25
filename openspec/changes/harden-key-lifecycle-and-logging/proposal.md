# Proposal

## Why

**Criticality:** P2 (Medium)
**Findings:** C-13, C-14, C-16 (`02-crypto.md`); S-19 (`03-sync-read.md`); CF-22
(`06-client-features.md`); A-21, A-18 (`01-auth-session.md`, documentation only)

SECURITY.md promises more than the code does about key material in memory, and debug mode logs
more than it should. None of this is exploitable without access to the Mac's memory or logs, but
it breaks Constitution §III and the project's public security claims.

- **Org keys survive sign-out (C-13, S-19).** `signOut()` clears `vaultKeyCache` but not
  `OrgKeyCache` (`Prizm/App/PrizmApp.swift:458-470`). The organization keys of the signed-out
  account stay on the heap until the app quits or the vault is locked. SECURITY.md:98 says "all
  in-memory key material is zeroed". `OrgKeyCache.swift:13` says it is "cleared … on vault lock and
  sign-out".
- **Org keys survive leaving an org (C-16).** Sync clears `OrgKeyCache` only when the new response
  has organizations and a private key (`SyncRepositoryImpl.swift:133-150`). After the user leaves
  their last org, or when the private key fails to decrypt, old org keys stay until lock.
- **Master key and stretched keys are never zeroed (C-14).** They are `let` locals in
  `AuthRepositoryImpl` (`:105-121`, `:306-318`). After a successful 2FA login and on sign-out,
  `pendingTwoFactor` (which holds the stretched keys) is set to `nil` without zeroing (`:227`,
  `:425`). The decrypted user-key buffer in `decryptSymmetricKey` is not zeroed. The vendored
  Argon2 wrapper frees its output buffers without zeroing them. SECURITY.md:72-73 says the master
  key is "zeroed on lock or sign-out".
- **Debug logging (CF-22).** With `--debug-mode`, every token-request parameter except `password`
  is logged with `privacy: .public` (`PrizmAPIClient.swift:472-479`), including the email
  (`username`) and the 2FA code (`twoFactorToken`). Public log fields are readable by any process
  with log access and end up in sysdiagnose archives. `Config.swift:36-37` says debug output never
  contains "key material or tokens".
- **SECURITY.md is wrong in two more places.** The device identifier is "deleted on sign-out"
  (`SECURITY.md:82`); the code keeps it, which matches official clients (A-21). The biometric design
  says the approach is "the same model used by Bitwarden's official clients" and puts the key
  "behind the Secure Enclave" (A-18). iOS uses the same model; desktop macOS does not, and keychain
  items are not stored in the Secure Enclave.

### Origin of the current behaviour

- C-13 / S-19: **accidental.** The org-support spec requires clearing on lock only
  (`openspec/changes/archive/2026-04-19-org-support/specs/org-key-crypto/spec.md:35-37`); sign-out
  was missed. `signOut` and the lock path were written separately (`923fa5b`).
- C-16: **accidental** (the `clear()` sits inside the `if`).
- C-14: **accidental.** The SECURITY.md claim was never implemented.
- CF-22: scrubbing the password is **deliberate** ("password scrubbed"); logging the email and 2FA
  code is **accidental**.
- A-21: **accidental** doc error. A-18: **wrong premise** in
  `openspec/changes/archive/2026-04-12-biometric-vault-unlock/design.md:30` (`2798a7a`); the
  design itself is sound.

## What Changes

- **One teardown path.** `AuthRepositoryImpl.lockVault()` zeroes and clears the vault key, the
  per-item key cache and the org key cache. Lock, sign-out and "sign in with a different account"
  all go through it.
- **Sync replaces org keys.** Built on the atomic swap of `fix-org-key-required-on-write`: when
  the org step fails (private key not decryptable), the keys are replaced with an empty map too.
- **Transient keys are zeroed.** Master key, stretched keys, the decrypted user-key buffer and the
  pending-2FA keys are zeroed as soon as they are no longer needed, on every path (success, error,
  2FA, cancel, sign-out). The vendored Argon2 wrapper zeroes its buffers before freeing them.
- **Debug logging uses an allow-list.** Only non-identifying token parameters are logged as
  public; email and 2FA code are never logged, and debug lines that may contain server text are
  `.private`.
- **SECURITY.md** matches the code: key lifetimes, device identifier, biometric comparison with
  official clients, and Swift's limits on zeroing (copy-on-write copies).

## Capabilities

### New Capabilities
- `key-lifecycle`: when key material is zeroed and cleared, and what debug logging may contain.

### Modified Capabilities
_None._ Related existing specs: `openspec/specs/vault-lock` (lock triggers) and
`openspec/specs/org-key-crypto` (cache cleared on lock). They are not edited; they do not pass
strict validation.

## Non-Goals

- Guaranteed erasure of every copy. Swift `Data` is copy-on-write; copies made by Foundation,
  CommonCrypto or in-flight tasks cannot be reached. This change zeroes the copies Prizm owns and
  documents the limit.
- Moving keys to `mlock`ed or Secure Enclave memory.
- Forced logout on a security-stamp change (A-12): `session-lifecycle`.
- Changing the biometric storage model (A-18 is a documentation fix only).
- Temp files of decrypted attachments (audit 05, A-12). Separate change.

## Dependencies

- **Soft:** `fix-kdf-derivation-and-validation` changes the same functions in `AuthRepositoryImpl`
  and `PrizmCryptoService`. Land that first; this change rebases.
- **Soft:** `fix-encstring-validation` changes `decryptSymmetricKey`. Either order works.

## Impact

- **Data:**
  - `AuthRepositoryImpl`: injected `VaultKeyCache` and `OrgKeyCache`; `lockVault`, `signOut`,
    login, unlock and 2FA paths zero their keys
  - `PrizmCryptoService.decryptSymmetricKey`: fresh key buffers, zeroed scratch buffer
  - `SyncRepositoryImpl`: `orgKeyCache.clear()` moved before the org block
  - `PrizmAPIClient`: debug allow-list
  - `LocalPackages/Argon2Swift`: zero `hash` and `encoded` before `deallocate`
- **App:** `AppContainer` wiring; `PrizmApp.signOut` / `lockVault` no longer clear caches themselves.
- **Presentation:** `UnlockViewModel.signInWithDifferentAccount` unchanged in behaviour (it already
  calls `auth.signOut()`, which now clears everything).
- **Docs:** SECURITY.md, `Config.swift` comment, `OrgKeyCache.swift` comment, CHANGELOG.
- **No new dependencies.**
- **Security review: yes** (§III: key material lifetime, logging of secrets).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Single teardown path, sign-out clears org keys | 0.5 d |
| 2 | Sync clears org keys every time | 0.25 d |
| 3 | Zeroing of master, stretched, user-key and 2FA buffers; Argon2 wrapper | 1 d |
| 4 | Debug-log allow-list and review of `.public` debug lines | 0.25–0.5 d |
| 5 | SECURITY.md and comments, security review, CHANGELOG | 0.5 d |
| **Total** | | **2.5–2.75 d** |
