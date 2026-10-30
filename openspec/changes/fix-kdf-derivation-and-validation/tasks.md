# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite for group 6 only:** `fix-prelogin-identity-endpoint` has landed.

## 1. Known-answer tests and open facts (0.5 d)

- [ ] 1.1 Add `KdfKnownAnswerTests` with vectors computed by independent reference implementations on the SDK tests' inputs (design.md, "Known-answer vectors"): PBKDF2 and Argon2id master keys, PBKDF2 server hashes for three email spellings and the Argon2id server hash. The Argon2id cases and the ` test@bitwarden.com` case fail today.
- [ ] 1.2 Open Question 3: decided moot (design.md).

## 2. Argon2id fix (0.5 d)

- [ ] 2.1 `argon2idDerive`: SHA-256 of the salt (CryptoKit), `memory * 1024` as KiB. §VII comment: RFC 9106, SDK `kdf.rs:54,65`, why the salt is hashed. The Argon2id KATs from 1.1 pass.
- [ ] 2.2 `KdfParams.memory` doc comment says MiB. Change the `65536` fixture in `EntityValidationTests` to `64`.

## 3. KDF validation (1 d)

- [ ] 3.1 Failing table-driven tests for `KdfValidator`, mirroring SDK `test_derive_kdf_minimums`: PBKDF2 4999 rejected, 5000 accepted; Argon2id iterations 1, memory 15, parallelism 0 rejected; 2/16/1 accepted; memory 1025 and parallelism 17 rejected (D4); negative, zero and `Int.max` rejected without a trap; Argon2id without memory or parallelism rejected.
- [ ] 3.2 Implement `KdfValidator` and call it at the top of `makeMasterKey`. New `PrizmCryptoServiceError.insufficientKdfParameters` (below minimums) and `.invalidKdfParameters` (unusable values, D4 caps).
- [ ] 3.3 Failing tests (mock API): prelogin returns PBKDF2 with 1 iteration, and in a second case Argon2id with 15 MiB. Login throws `AuthError.kdfSettingsTooWeak` and `identityToken` is never called. A third case with a negative value throws `AuthError.invalidKdfSettings`.
- [ ] 3.4 Failing test: stored KDF settings below the minimum make unlock throw `AuthError.kdfSettingsTooWeak`, and no key is derived.
- [ ] 3.5 `AuthError.kdfSettingsTooWeak` and `.invalidKdfSettings` with their messages (design.md D2). `LoginViewModel` and `UnlockViewModel` show them in the existing error area, read by VoiceOver like the other login errors (§VIII). Test the mapping. No warn-and-continue path.

## 4. Salt and email normalization (0.5–1 d)

- [ ] 4.1 Failing tests: ` User@Example.com ` and `user@example.com` give the same master key; a non-ASCII email gives the same bytes as the SDK's `to_lowercase()` (generate the vector with the SDK, or document the difference).
- [ ] 4.2 Normalize the email once in `loginWithPassword` and use it for prelogin, salt and `username`. Rename `makeMasterKey(password:email:kdf:)` to `makeMasterKey(password:salt:kdf:)`; the crypto service trims and lowercases the salt.
- [ ] 4.3 Failing test: prelogin `salt` = `"Other@Example.com"` is used (normalized) instead of the email; `salt: null` falls back to the email.
- [ ] 4.4 Store the salt that worked under `masterPasswordSalt`. Unlock uses it; without it (existing install) unlock falls back to the stored email, normalized. Sign-out deletes it. Tests for all three.

## 5. New response fields and legacy adapters (0.75–1 d)

- [ ] 5.1 Failing decode tests with fixtures: Vaultwarden 1.37.4 prelogin; official prelogin with `kdfSettings` and a `salt`; a prelogin with only `kdfSettings` (flat fields removed); a Vaultwarden 1.35.4 prelogin with only flat fields. Each yields the expected settings. When `kdfSettings` is present and the flat fields disagree, `kdfSettings` wins and the legacy flat fields are not read (shown by flat fields of the wrong JSON type: decoding fails only if `LegacyPreloginKdfFields` reads them).
- [ ] 5.2 Failing decode tests for the token response: Vaultwarden 1.37.4 (PascalCase `UserDecryptionOptions.MasterPasswordUnlock`), camelCase variant, and a Vaultwarden 1.34.0-style response with only top-level `Key` and `Kdf*`. When `MasterPasswordUnlock` is present, the legacy top-level fields are not read (wrong-typed `Key`/`Kdf*` fields: decoding fails only if `LegacyTokenUserKeyFields` reads them).
- [ ] 5.3 Implement D5 in `PreLoginResponse` and `TokenResponse` with a first-letter-case-insensitive key strategy for these two types. Put the flat-field and top-level-field readers in `Data/Network/Legacy/LegacyPreloginKdfFields.swift` (marker `// LEGACY(Vaultwarden < 1.37.0, Bitwarden server < v2025.12.0): remove when those versions are no longer supported`) and `Data/Network/Legacy/LegacyTokenUserKeyFields.swift` (marker `// LEGACY(Vaultwarden < 1.35.4, Bitwarden server < v2025.8.0): remove when those versions are no longer supported`). Add both to the "Legacy adapters" table in `FIX-ORDER.md` if missing.
- [ ] 5.4 Implement D6: store the settings and salt that decrypted the user key; remove `?? 600_000`; log an `.error` without values when `MasterPasswordUnlock.kdf` differs. Tests.

## 6. Release (0.5 d)

- [ ] 6.1 Interop check on the rig (Vaultwarden 1.37.4): log in, lock, unlock with a PBKDF2 account and with an Argon2id account (default 6 / 32 MiB / 4 and 3 / 64 MiB / 4). Also log in to an account with 15 MiB memory and confirm the "too weak" error. Log in to a Vaultwarden 1.35.4 container if one can be started (legacy adapters); otherwise record that 5.1 and 5.2 cover it. If an official self-hosted server is available, repeat with an account registered there.
- [ ] 6.2 Mandatory security review: salt and memory handling, validation placement (login and unlock), no KDF values or salts in `.public` logs, error mapping.
- [ ] 6.3 SECURITY.md: Argon2id row (SHA-256 salt, MiB), a "KDF minimums" paragraph with the SDK values and the D4 caps, salt storage in the Keychain table.
- [ ] 6.4 CHANGELOG "Fixed": accounts using Argon2id can sign in; an email typed with surrounding spaces no longer fails. "Security": Prizm refuses to sign in to accounts with weak key-derivation settings, as the official apps do (PBKDF2 below 5000 iterations, Argon2id below 16 MiB, 2 iterations or parallelism 1); raise them in the web vault.
- [ ] 6.5 `/code-review`, `openspec validate fix-kdf-derivation-and-validation --type change --strict`, `/opsx:verify`.
- [ ] 6.6 Archive the change (at the end of the batch, in PR order).
