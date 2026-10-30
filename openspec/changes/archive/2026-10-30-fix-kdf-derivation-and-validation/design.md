# Design

## Context

### Official derivation (Bitwarden SDK)

Source: `sdk-internal/crates/bitwarden-crypto/src/keys/kdf.rs` at HEAD 2026-10-23.

- Minimums (`:12-16`): `PBKDF2_MIN_ITERATIONS = 5000`; `ARGON2ID_MIN_MEMORY = 16 * 1024` (KiB);
  `ARGON2ID_MIN_ITERATIONS = 2`; `ARGON2ID_MIN_PARALLELISM = 1`. Below these, derivation fails
  with `InsufficientKdfParameters` (`:39-41`, `:58-63`). Tested in `test_derive_kdf_minimums`
  (`:182-219`).
- PBKDF2-SHA256 over the salt bytes, 32-byte output (`:37-47`).
- Argon2id (`:49-79`): `memory = memory.get() * 1024; // Convert MiB to KiB` (`:54`);
  `salt_sha = Sha256(salt)` (`:65`); `Params::new(memory, iterations, parallelism, Some(32))`,
  `Algorithm::Argon2id`, `Version::V0x13` (`:70-72`).
- `derive(password, email, kdf)` trims and lowercases the email before use (`:84-93`).
- Known-answer tests: `test_master_key_derive_pbkdf2` (`:221-239`: password `67t9b5g67$%Dh89n`,
  salt `test_key`, 10 000 iterations) and `test_master_key_derive_argon2` (`:241-259`: same input,
  iterations 4, memory 32 MiB, parallelism 2). `keys/master_key.rs:229-256` checks that
  `test@bitwarden.com`, `TEST@bitwarden.com` and ` test@bitwarden.com` give the same server hash
  `wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=` (PBKDF2 100 000). `master_key.rs:258-278` gives
  `PR6UjYmjmppTYcdyTiNbAhPJuQQOmynKbdEl1oyi/iQ=` for Argon2id (salt `test_salt`, 4 / 32 / 2).

### Official prelogin handling

- TS: `PBKDF2KdfConfig.PRELOGIN_ITERATIONS_MIN = 5000`; `Argon2KdfConfig.PRELOGIN_MEMORY_MIN = 16`
  (MiB), `PRELOGIN_ITERATIONS_MIN = 2`, `PRELOGIN_PARALLELISM_MIN = 1`. Errors say "possible
  pre-login downgrade attack detected" (`clients/libs/legacy-crypto/src/models/kdf-config.ts:19`,
  `:46-52`, `:75-77`, `:126-140`). There is no upper bound at prelogin.
- TS reads `KdfSettings` and `Salt` (`clients/libs/common/src/auth/password-prelogin/password-prelogin.response.ts:10-11`)
  and validates (`password-prelogin.model.ts:24`; `default-password-prelogin.service.ts:75`). The
  email is normalized with `email.trim().toLowerCase()` before prelogin
  (`default-password-prelogin.service.ts:28`).
- TS uses the server salt only behind feature flag `pm-27060-password-prelogin-from-sdk`
  (`clients/libs/auth/src/common/login-strategies/password-login.strategy.ts:151-198`), default
  FALSE (`clients/libs/common/src/enums/feature-flag.enum.ts:178`). Otherwise the email is the salt.
- SDK: `PasswordPreloginResponse::try_from` requires `kdf_settings` and uses
  `response.salt.unwrap_or_else(|| email.trim().to_lowercase())`
  (`sdk-internal/crates/bitwarden-auth/src/login/login_via_password/password_prelogin_response.rs:23-52`).
  A comment there says the email fallback stays until PM-28143.

### Servers

- Official prelogin response: flat `Kdf`, `KdfIterations`, `KdfMemory`, `KdfParallelism` marked
  "PM-28143 Remove with cleanup"; `KdfSettings` and `Salt` ("Not used yet, just the email from the
  request at this time") (`server/src/Identity/Models/Response/Accounts/PasswordPreloginResponseModel.cs:28-37`).
  The salt is `UserKdfInformation.MasterPasswordSalt` (`server/src/Identity/Controllers/AccountsController.cs:237-241`),
  set at registration (`server/src/Infrastructure.Dapper/Repositories/UserRepository.cs:544`).
  `User.GetMasterPasswordSalt()` returns `MasterPasswordSalt ?? Email.ToLowerInvariant().Trim()`
  (`server/src/Core/Entities/User.cs:138-141`).
- Official token response: top-level `Key` "deprecated in favor of
  UserDecryptionOptions.MasterPasswordUnlock.MasterKeyEncryptedUserKey"; flat `Kdf*` still sent
  (`server/src/Identity/IdentityServer/RequestValidators/BaseRequestValidator.cs:640-652`).
  `MasterPasswordUnlock` = `{ Kdf { KdfType, Iterations, Memory, Parallelism },
  MasterKeyEncryptedUserKey, Salt = GetMasterPasswordSalt() }`
  (`server/src/Identity/IdentityServer/UserDecryptionOptionsBuilder.cs:185-201`).
- Vaultwarden 1.37.4 prelogin: flat fields, `kdfSettings`, `"salt": null`
  (`vaultwarden/src/api/core/accounts.rs:1412-1424`). Token response: flat `Kdf*`, `Key`, and
  `UserDecryptionOptions.MasterPasswordUnlock` with `Kdf`, `MasterKeyEncryptedUserKey`,
  `MasterKeyWrappedUserKey` and `Salt: user.email` (`vaultwarden/src/api/identity.rs:536-591`).
- Allowed values when a user sets the KDF:
  - Official: PBKDF2 600 000–2 000 000; Argon2 iterations 2–10, memory 15–1024 MiB, parallelism
    1–16 (`server/src/Core/KeyManagement/Kdf/KdfConstants.cs:10-14`).
  - Vaultwarden: PBKDF2 ≥ 100 000; Argon2 iterations ≥ 1, memory 15–1024 MiB, parallelism 1–16
    (`vaultwarden/src/api/core/accounts.rs:683-705`).
  - Both servers therefore allow Argon2 memory 15 MiB, and Vaultwarden allows 1 Argon2 iteration,
    which the SDK and the TS clients refuse. PBKDF2 below 5000 can't be set on either server today,
    but an old account may still have it.
- Field availability by version:
  - prelogin `kdfSettings`: Vaultwarden from 1.37.0, Bitwarden from v2025.12.0. Older servers send
    only the flat `kdf*` fields.
  - token `UserDecryptionOptions.MasterPasswordUnlock`: Vaultwarden from 1.35.4, Bitwarden from
    v2025.8.0. Older servers send only the top-level `Key` and `Kdf*`.
  - Prizm today reads only the flat prelogin fields and the top-level token fields, so it works on
    all of these servers. This change must keep that (compatibility rule, `FIX-ORDER.md`).
- Response key casing: Vaultwarden sends PascalCase inside `UserDecryptionOptions`. The TS
  `BaseResponse.getResponseProperty` and the iOS `pascalOrSnakeCaseDecoder`
  (`ios/BitwardenKit/Core/Platform/Services/API/Extensions/JSONDecoder+Bitwarden.swift:38-47`)
  both accept PascalCase and camelCase.

### Prizm today

- `makeMasterKey(password:email:kdf:)` (`Prizm/Data/Crypto/PrizmCryptoService.swift:351-378`):
  salt = `email.lowercased()` bytes; no check of the parameters; `UInt32(kdf.iterations)` traps on
  negative values.
- `argon2idDerive` (`:702-729`) passes the salt and `memory` straight to
  `Argon2Swift.hashPasswordBytes`, which calls `argon2_hash(t_cost, m_cost, …)` with `m_cost` in
  KiB (`LocalPackages/Argon2Swift/Sources/Swift/Argon2Swift.swift:64-90`, version default `.V13`).
- `KdfParams.memory` says "Memory cost in KiB" (`Prizm/Domain/Entities/KdfParams.swift:23`).
- Login (`Prizm/Data/Repositories/AuthRepositoryImpl.swift:196`) and unlock (`:411`) pass
  `email.lowercased()`; no trim.
- `PreLoginResponse` (`Prizm/Data/Network/PrizmAPIClient.swift:250-267`) has required `kdf` and
  `kdfIterations`; no `kdfSettings`, no `salt`.
- `TokenResponse` (`PrizmAPIClient.swift:273-310`) reads `Key` and flat `Kdf*` only.
- After login, the token response's KDF is stored with `kdfIterations ?? 600_000`
  (`AuthRepositoryImpl.swift`, `kdfParams(environment:)`, `:957-965`).

## Goals / Non-Goals

**Goals**
- Byte-identical master keys and server hashes to the SDK for PBKDF2 and Argon2id, proven by the
  SDK's own vectors.
- No derivation, and no request to `/connect/token`, with settings below the SDK minimums.
- Keep working when the server drops the flat fields (PM-28143).

**Non-Goals:** see proposal.md.

## Decisions

### D1. Argon2id: SHA-256 salt, memory in MiB

`argon2idDerive` hashes the salt bytes with CryptoKit `SHA256` and passes `memory * 1024` as
`m_cost`. Version 0x13 and 32-byte output stay. `KdfParams.memory` is documented as MiB, the unit
both servers use; the stored value does not change. The `65536` test fixture becomes `64`.

**No data migration.** Stored `kdfParams` already hold the server's MiB number. No Argon2id account
could log in before this change, so no stored Argon2id record was ever written. PBKDF2 records are
unaffected.

### D2. Validate before deriving, in the Data layer

A `KdfValidator` in `Data/Crypto` runs inside `makeMasterKey`, so login and unlock are both
covered, as in the SDK where the check sits in `derive_kdf_key`. Rules:
- PBKDF2: iterations ≥ 5000 and ≤ `UInt32.max`.
- Argon2id: iterations ≥ 2, memory ≥ 16 MiB, parallelism ≥ 1; memory and parallelism present.
- Anything else (unknown type, missing field, value ≤ 0) is rejected.

Two typed errors, both thrown before any derivation and before any request to `/connect/token`:
- Below the SDK minimums: `PrizmCryptoServiceError.insufficientKdfParameters`, mapped by
  `AuthRepositoryImpl` to `AuthError.kdfSettingsTooWeak`: "This account's key-derivation settings
  are too weak, so Prizm won't use them. Raise them in the web vault (Settings → Security → Keys),
  then sign in again."
- Unusable values (unknown type, missing field, zero, negative, above the D4 caps):
  `PrizmCryptoServiceError.invalidKdfParameters`, mapped to `AuthError.invalidKdfSettings`: "This
  account's key-derivation settings can't be used by Prizm. Contact your server administrator."
  Both texts also show at unlock, where the settings come from the Keychain, so neither names the
  server or signing in.

Login is refused. There is no warn-and-continue path, as in every official client: the TS clients
throw at prelogin ("possible pre-login downgrade attack detected", `kdf-config.ts:19,47-49,75-77`)
and the SDK fails derivation with `InsufficientKdfParameters` (`kdf.rs:12-16`).

**Deliberate parity decision.** Both servers let a user store settings that this refuses: Argon2
memory 15 MiB (Bitwarden `KdfConstants.cs:10-14`, Vaultwarden `accounts.rs:683-705`) and, on
Vaultwarden, 1 Argon2 iteration. Prizm refuses them anyway, like the official clients. This is a
security decision under the compatibility rule's exceptions, not a regression: Argon2id login does
not work in Prizm today (D1), and PBKDF2 below 5000 is accepted today only because nothing is
checked.

**Rejected:** checking only in `loginWithPassword`. Stored settings would then be trusted on
unlock, and a test would have to cover two places.

### D3. Salt: server salt if present, else email; always trimmed and lowercased

- Login normalizes the typed email once: `trimmingCharacters(in: .whitespacesAndNewlines)` and
  `lowercased()`. The normalized email is used for prelogin and as the token `username`.
- Salt = prelogin `salt` if non-empty, else the normalized email. The SDK's `derive` trims and
  lowercases whatever it gets (`kdf.rs:87-93`), so Prizm normalizes the salt too.
- The salt that decrypted the user key is stored in the Keychain
  (`bw.macos:{userId}:masterPasswordSalt`) and used on unlock. If absent (installs from before this
  change), unlock falls back to the stored email, normalized. Any other Keychain error while reading
  it is logged and refuses the unlock before a key is derived. Sign-out deletes it.

This follows the SDK path. The TS default (flag off) still uses the email. Both give the same
bytes for every account where the server salt equals the email, which is all accounts today.

**Rejected:** always use the email, ignore `salt`. Simpler, but breaks once the server decouples
salt and email, which is the stated goal of PM-28143.

### D4. Upper bounds for Argon2id memory and parallelism

Prizm rejects Argon2id memory > 1024 MiB and parallelism > 16. Both servers refuse to store larger
values (Context), so no real account has them, and they would let a server exhaust the Mac's
memory. Iterations get no upper bound: Vaultwarden has none for PBKDF2 or Argon2, and capping them
could lock out real accounts.

This is stricter than the SDK, which has no upper bound. **Rejected:** no caps (exact SDK parity).
It leaves a cheap denial of service open, and the caps cannot affect a real account.

### D5. Read the new fields first; old fields only in legacy adapters

- `PreLoginResponse`: `kdfSettings { kdfType, iterations, memory, parallelism }` is read first. Only
  when `kdfSettings` is absent are the flat `kdf`, `kdfIterations`, `kdfMemory`, `kdfParallelism`
  read, by `LegacyPreloginKdfFields` (`Prizm/Data/Network/Legacy/LegacyPreloginKdfFields.swift`),
  marked `// LEGACY(Vaultwarden < 1.37.0, Bitwarden server < v2025.12.0): remove when those versions are no longer supported`.
  All fields optional; if neither yields a type and iteration count, prelogin fails with
  `AuthError.invalidKdfSettings`. `salt` optional.
- `TokenResponse`: `UserDecryptionOptions.MasterPasswordUnlock` gives `masterKeyEncryptedUserKey`,
  `salt` and `kdf`. Only when `MasterPasswordUnlock` is absent are the top-level `Key` and `Kdf*`
  read, by `LegacyTokenUserKeyFields` (`Prizm/Data/Network/Legacy/LegacyTokenUserKeyFields.swift`),
  marked `// LEGACY(Vaultwarden < 1.35.4, Bitwarden server < v2025.8.0): remove when those versions are no longer supported`.
- When the new field is present, the legacy adapter is not consulted, even if the old fields are
  also present (Vaultwarden 1.37.4 sends both). Tests cover both directions.
- Keys are decoded case-insensitively for the first letter, as the TS and iOS clients do, because
  Vaultwarden sends PascalCase in the nested objects.

### D6. Store the settings that worked

After login, Prizm stores the KDF settings and salt that just decrypted the user key. That
removes the `?? 600_000` default. If `MasterPasswordUnlock.kdf` is present and differs from the
prelogin settings, Prizm logs an `.error` (no values) and still stores the settings that worked.

**Rejected:** store the token response's settings, as today. They are not the ones that were
proven, and the old fallback hides missing fields.

## Risks / Trade-offs

- **[Medium] Accounts with Argon2 memory 15 MiB or 1 iteration, or PBKDF2 below 5000** cannot log
  in. Official clients refuse them too (D2, parity decision). The error tells the user to raise
  the settings in the web vault.
- **[Low] Legacy adapters stay until old servers are dropped.** → Each is one small file with a
  `LEGACY` marker and is listed in `FIX-ORDER.md`, "Legacy adapters".
- **[Low] Unicode case folding.** Swift `lowercased()`, Rust `to_lowercase()` and .NET
  `ToLowerInvariant()` can differ for some non-ASCII characters. → Test with an ASCII and a
  non-ASCII email (task 4.1); document any difference.
- **[Low, accepted] Huge iteration counts.** Iterations are capped only at `UInt32.max` (D4), so a
  hostile server can make a derivation run for a very long time. It costs CPU time, not secrets;
  the user can quit Prizm. A tighter cap could lock out real accounts, since neither server caps
  PBKDF2 iterations.
- **[Low] Server salt that differs from the email** on the official server. → Prizm uses it, as the
  SDK does. No official server was available for task 6.1; unit tests cover it
  (`testLogin_usesServerSalt_normalized`).

## Known-answer vectors

The vectors in `KdfKnownAnswerTests` are computed with independent reference implementations, not
copied from the SDK's tests (the same rule as `ssh-key-import-and-generation` D8): Python `hashlib`
(PBKDF2-SHA256) and `argon2-cffi` (Argon2id, version 0x13). They use the SDK tests' inputs (listed in
Context), so they can be checked against the SDK's published results: the PBKDF2 server hash for all
three email spellings (`wmyadRMy…`) and the Argon2id server hash (`PR6UjYmj…`) come out identical.
That confirms D1 (SHA-256 salt, memory in MiB) without using SDK code.

## Review

Independent review on 2026-10-30 (fresh reviewer, `git diff` against `origin/develop`, nothing
built). The reviewer recomputed the PBKDF2 vectors with Python `hashlib`; Argon2id could not be
recomputed there, but its server hash equals the SDK's published one and Argon2id accounts log in
on the rig. No blockers. Findings:

- Fixed (S1): unlock read the stored salt with `try?`, so any Keychain error fell back to the email
  and showed up as a wrong password, with no log. Now only a missing entry falls back (installs from
  before this change); any other error is logged and stops the unlock before a key is derived
  (`testUnlock_saltReadFails_isReported_withoutDeriving`).
- Fixed (N1): iteration counts are capped only at `UInt32.max`, so a hostile server can make a
  derivation run for a very long time. Recorded as an accepted risk in Risks, in `KdfValidator`'s
  doc comment and in SECURITY.md.
- Fixed (N2): the parallelism minimum check could never fire, since the range check already refuses
  values below 1. The dead branch is gone; a comment says the range check enforces it.
- Fixed (N3): two new helpers had been inserted between `twoFactorMethod`'s doc comment and its
  function. The comment is back on its function.
- Fixed (N4): the KDF error texts named the server and signing in, but they also show at unlock,
  where the settings come from the Keychain. Both texts are neutral now (D2).
- Fixed (N5): tasks 5.1 and 5.2 asked for spies; the tests give the legacy fields a wrong JSON type
  instead, so decoding fails only if a legacy reader runs. The tasks now say so.
- Fixed (process): the CHANGELOG entry and the TDD note for the tests written after the code were
  missing; both are in the archive (tasks.md, CHANGELOG).

### Security

Mandatory review (task 6.2), of the code as it is now, against the Bitwarden SDK rules in Context.

- **Salt and memory.** The master password salt is the server's prelogin `salt` when it is
  non-empty, otherwise the typed email; both are trimmed and lowercased, and the crypto service
  normalizes the salt again before use. PBKDF2-SHA256 runs over the salt's UTF-8 bytes. For
  Argon2id the Argon2 salt is the SHA-256 of those bytes and the server's memory value is read as
  MiB and multiplied by 1024 (version 0x13, 32-byte output). The server hash is
  PBKDF2(masterKey, password, 1), unchanged. Known-answer vectors from independent implementations
  match the SDK's published server hashes, and the PBKDF2 and Argon2id rig accounts log in, lock
  and unlock.
- **Validation placement.** `KdfValidator` runs first inside `makeMasterKey`, which login and unlock
  both reach through `deriveMasterKey`. Settings below the SDK minimums, and unusable ones (unknown
  type, missing, zero or negative values, Argon2id memory above 1024 MiB or parallelism above 16),
  are refused before any derivation, so at login nothing is sent to `/connect/token`. Stored
  settings are checked again at unlock. Biometric unlock and the 2FA step derive no key. There is no
  warn-and-continue path.
- **Stored settings and salt.** Prizm stores the settings and salt that decrypted the user key, not
  the token response's values (no more 600 000 default). If `MasterPasswordUnlock.kdf` differs, an
  `.error` without values is logged. Unlock falls back to the email only when no salt is stored; any
  other Keychain error stops the unlock. Sign-out deletes the salt.
- **Logs.** No KDF values, salts or emails in `.public` logs. Public lines carry the KDF type and
  booleans (settings present, server salt used, salt stored); the email is `.private`; refusals are
  logged without values; Keychain errors go through `ErrorLog.describe`.
- **Error mapping.** `insufficientKdfParameters` maps to `AuthError.kdfSettingsTooWeak` and
  `invalidKdfParameters` to `AuthError.invalidKdfSettings`; both show in the existing login and
  unlock error areas, never as "invalid credentials". A Keychain failure while reading the salt shows
  the existing "invalid credentials" text, as the other Keychain failures in unlock do.
- **Accepted risk.** Huge iteration counts can keep the CPU busy (N1); they cost time, not secrets.
- **Not covered live.** A server salt that differs from the email (no official self-hosted server
  in the rig) is covered by unit tests only.

Archive pass and hand check (2026-10-30):
- Fixed: VoiceOver never read a sign-in or unlock error, and after a refused sign-in focus went back
  to the server URL field. Errors are announced at high priority through AppKit (on the login
  screen one second after it reappears, so the screen change does not drop it), and focus goes to
  the password field. Confirmed by Christian with VoiceOver on rig account D (15 MiB).
- Fixed: comments and SECURITY.md wording (salt hash reason, where invalid settings come from, the
  refusal also at unlock); spec scenario and design text name the independently computed vectors,
  the unlock refusal on a Keychain error, and the missing official-server check.

## Open Questions

None. Decided 2026-10-30 (batch run, with the defaults the questions proposed):
1. Prizm uses the server `salt` now (SDK path, D3). For every current account it gives the same bytes
   as the email.
2. The upper bounds of D4 stay.
3. Moot for Prizm: it sends the email trimmed and lowercased as the token `username`, exactly as the
   TS clients do (`email.trim().toLowerCase()`), so the official server sees the same value it gets
   from them. Vaultwarden trims it as well (`vaultwarden/src/api/identity.rs:378`).
