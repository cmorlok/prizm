# Proposal

## Why

**Criticality:** P0 (Critical)
**Findings:** A-02, A-04, A-06, A-08 (`01-auth-session.md`); C-02, C-03, C-06, C-12 (`02-crypto.md`)

Prizm derives the master key differently from Bitwarden in three ways, and it trusts the server's
KDF settings without any check.

1. **Argon2id accounts cannot log in.** Two bugs in `argon2idDerive`
   (`Prizm/Data/Crypto/PrizmCryptoService.swift:351-378`, `:702-729`) each give a wrong master key:
   - The salt is the raw lowercased email. Bitwarden uses **SHA-256** of the email as the Argon2
     salt.
   - The server sends Argon2 memory in **MiB**. Prizm passes the number to Argon2 as KiB, so it
     uses 64 KiB instead of 64 MiB.
   The server then rejects the password hash, and the user sees "Invalid email or master password".
   README advertises Argon2id support (`README.md:105`). Argon2id is a choice offered in every
   official client's settings.
2. **A server can make Prizm send a weak password hash.** Prizm accepts any KDF settings from
   prelogin, including PBKDF2 with 1 iteration. A malicious or compromised server, or anyone who
   can answer the prelogin request, receives a server hash that is cheap to brute-force offline.
   Official clients reject such settings as a "possible pre-login downgrade attack". Negative values
   also crash Prizm (`UInt32(...)` traps).
3. **The salt is not trimmed.** Typing the email with a leading or trailing space gives a different
   master key and a misleading "invalid credentials" error.
4. **Prizm reads only fields the server has marked for removal.** The prelogin flat fields
   (`kdf`, `kdfIterations`, …) are marked "PM-28143 Remove with cleanup". Top-level `Key` in the
   token response is "deprecated in favor of UserDecryptionOptions.MasterPasswordUnlock". Prizm
   also stores the token response's KDF settings with a silent default of 600 000 iterations when
   they are missing (`AuthRepositoryImpl.swift`, `kdfParams(environment:)`).

### Origin of the current behaviour

- Argon2id salt: **accidental.** The design only says "Argon2id(password, salt, …)"
  (`openspec/changes/archive/2026-03-15-vault-browser-ui/design.md:84`). No Argon2 known-answer
  test exists; `PrizmCryptoServiceTests.swift` checks only length and determinism.
- Argon2 memory unit: **wrong premise.** `KdfParams.swift:23`: "Memory cost in KiB … (Bitwarden
  default 64 MiB = 65536 KiB)", added in `5b893b0`. The test fixture uses `memory: 65536`
  (`PrizmTests/Domain/EntityValidationTests.swift:84`).
- KDF minimums, trim, new fields: **accidental.** No trace in specs, SECURITY.md or tests.

## What Changes

- **Argon2id matches Bitwarden:** salt = SHA-256(salt string), memory = server value × 1024 KiB,
  Argon2 version 0x13, 32-byte output. `KdfParams.memory` is documented as MiB.
- **Minimum KDF settings, as in the SDK:** PBKDF2 ≥ 5000 iterations; Argon2id memory ≥ 16 MiB,
  iterations ≥ 2, parallelism ≥ 1. Checked before every derivation (login and unlock). Values that
  do not fit the KDF API (zero, negative, too large) are rejected instead of trapping. Argon2id
  memory above 1024 MiB and parallelism above 16 are rejected (design.md D4).
- **Login is refused, with a clear error:** settings below the minimums stop login with
  "This account's key-derivation settings are too weak … Raise them in the web vault". Unusable
  values get a separate typed error. Neither is "invalid credentials", and nothing is sent to
  `/connect/token`. There is no warn-and-continue, as in every official client. Argon2 memory
  15 MiB and (Vaultwarden) 1 iteration are allowed by the servers but refused here on purpose
  (design.md D2).
- **Salt:** the prelogin `salt` when the server sends one, otherwise the email. Either way trimmed
  and lowercased, as in the SDK. The salt used is stored for offline unlock.
- **New response fields first, old ones in legacy adapters:** prelogin reads `kdfSettings`; only
  if it is absent, `LegacyPreloginKdfFields` reads the flat fields (Vaultwarden < 1.37.0, Bitwarden
  < v2025.12.0). The token response reads `UserDecryptionOptions.MasterPasswordUnlock` (`kdf`,
  `salt`, `masterKeyEncryptedUserKey`); only if it is absent, `LegacyTokenUserKeyFields` reads the
  top-level `Key` and `Kdf*` (Vaultwarden < 1.35.4, Bitwarden < v2025.8.0). Every server where
  login works today keeps working. The stored KDF settings are the ones that just decrypted the
  user key. The 600 000 default goes away.
- **Known-answer tests** for PBKDF2 and Argon2id, computed with independent reference
  implementations on the SDK tests' inputs and matching the SDK's published results.

## Capabilities

### New Capabilities
- `master-key-derivation`: deriving the master key from password, salt and KDF settings the way
  Bitwarden does, and refusing unsafe settings.

### Modified Capabilities
_None._ Related existing specs: `openspec/specs/vault-browser-ui` (login) and
`openspec/specs/project-documentation` (README names Argon2id). Neither specifies the derivation.

## Non-Goals

- Changing the account's KDF (the "KDF settings" screen of official clients).
- Legacy (type-0 / 32-byte) and v2 (COSE) user keys (C-08, C-09). Separate change.
- Forced logout when the KDF changes on another device (A-12, security stamp): `session-lifecycle`.
- Zeroing master and stretched keys: `harden-key-lifecycle-and-logging`.
- The prelogin endpoint path: `fix-prelogin-identity-endpoint`.

## Dependencies

- **Hard (for the interop check only):** `fix-prelogin-identity-endpoint`, landed (fork PR #23).
- **Soft:** `harden-key-lifecycle-and-logging` changes the same functions (zeroing). Land this
  change first; that one rebases.

## Impact

- **Domain:** `KdfParams` doc comments (memory in MiB); new `AuthError.kdfSettingsTooWeak` and
  `AuthError.invalidKdfSettings` with user-facing messages.
- **Data:**
  - `PrizmCryptoService.makeMasterKey(password:salt:kdf:)` (renamed parameter), `argon2idDerive`,
    new `KdfValidator` (minimums, ranges)
  - `PreLoginResponse` (`kdfSettings`, `salt`); new `Data/Network/Legacy/LegacyPreloginKdfFields.swift`
  - `TokenResponse` (`UserDecryptionOptions.MasterPasswordUnlock`); new
    `Data/Network/Legacy/LegacyTokenUserKeyFields.swift`
  - `AuthRepositoryImpl.loginWithPassword` / unlock (normalized email, stored salt, stored KDF from
    the derivation that succeeded); sign-out deletes the stored salt
- **Presentation:** `LoginViewModel` / `UnlockViewModel` show the new error; VoiceOver reads it
  as for other login errors.
- **Docs:** SECURITY.md (KDF row, minimums), CHANGELOG.
- **No new dependencies.** SHA-256 comes from CryptoKit; Argon2 stays the vendored `Argon2Swift`.
- **Security review: yes** (§III: KDF, salt, downgrade protection).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Known-answer tests from the SDK (fail first) | 0.5 d |
| 2 | Argon2id salt and memory fix | 0.5 d |
| 3 | KDF validation, typed error, login and unlock paths, UI message | 1 d |
| 4 | Salt and email normalization, stored salt | 0.5–1 d |
| 5 | `kdfSettings` and `MasterPasswordUnlock` decoding; two legacy adapters with tests | 0.75–1 d |
| 6 | Interop check (PBKDF2 and Argon2id), security review, docs | 0.5 d |
| **Total** | | **3.75–4.5 d** |
