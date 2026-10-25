# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
Land after `fix-kdf-derivation-and-validation` if both are in flight (soft dependency).

## 1. One teardown path (0.5 d)

- [ ] 1.1 Failing test: store an org key in `OrgKeyCache`, call `AuthRepositoryImpl.signOut()`, assert the cache is empty and the stored key's buffer is zero (test seam as in `OrgKeyCryptoKATTests.swift:47`).
- [ ] 1.2 Failing test: `UnlockViewModel.signInWithDifferentAccount()` leaves both caches empty.
- [ ] 1.3 Inject `VaultKeyCache` and `OrgKeyCache` into `AuthRepositoryImpl` (`AppContainer`). `lockVault()` clears both after zeroing the vault key (design.md D1). Remove the cache clearing from `PrizmApp.signOut()` and `PrizmApp.lockVault()`. Existing lock tests still pass.

## 2. Sync replaces org keys (0.25 d)

- [ ] 2.1 Failing tests: (a) sync with orgs, then a sync with `organizations: []` → cache empty; (b) sync whose `privateKey` fails to decrypt → cache empty and org items excluded.
- [ ] 2.2 Move `orgKeyCache.clear()` before the org block in `SyncRepositoryImpl` (D2). Update the comment.

## 3. Zero transient keys (1 d)

- [ ] 3.1 Failing tests with test seams: after `loginWithPassword` (no 2FA), the master key and stretched key buffers are zero; after unlock, the same; after a thrown error in either path, the same.
- [ ] 3.2 Failing tests: the pending-2FA stretched keys are zero after TOTP success, after cancel and after sign-out during the 2FA step.
- [ ] 3.3 Implement D3 in `AuthRepositoryImpl` (`var` + `defer`, `clearPendingTwoFactor()`), with §VII comments on the copy-on-write caveat.
- [ ] 3.4 `decryptSymmetricKey`: copy the halves into fresh `Data`, zero `keyData`. Test: the returned keys still decrypt a type-2 vector; the scratch buffer is zero.
- [ ] 3.5 Argon2Swift: zero `hash` and `encoded` before `deallocate`; `argon2idDerive` zeroes the result arrays. Bump the vendored version suffix and note the patch. The Argon2id KATs still pass.

## 4. Debug logging (0.25–0.5 d)

- [ ] 4.1 Failing test: `debugDescription(ofTokenParams:)` for a request with `username`, `password`, `twoFactorToken` and `deviceIdentifier` contains none of their values and contains `grant_type`, `client_id` and `twoFactorProvider` (D4).
- [ ] 4.2 Use it in `identityToken`; make the non-JSON 400 body `.private`.
- [ ] 4.3 Review every `DebugConfig.isEnabled` block in `Prizm/` for `.public` emails, tokens, URLs with query secrets or server text; fix and list the changed lines in the PR description.

## 5. Docs and release (0.5 d)

- [ ] 5.1 SECURITY.md per design.md D5: key table (`:72-82`), lifecycle steps 3 and 4 (`:94-99`), a "Limits of zeroing in Swift" paragraph, the biometric comparison with iOS and desktop.
- [ ] 5.2 Correct the comments in `Config.swift:36-37`, `OrgKeyCache.swift:13,52` and `AppContainer.swift:26`.
- [ ] 5.3 Mandatory security review: every key buffer listed in SECURITY.md is zeroed where the doc says; no secret in `.public` logs; teardown order (zero before release).
- [ ] 5.4 CHANGELOG "Security": organization keys are cleared on sign-out and when a sync no longer lists the organization; master and stretched keys are zeroed after use; debug mode no longer logs the email or the two-factor code. "Docs": SECURITY.md corrections (device identifier, biometric comparison).
- [ ] 5.5 `openspec validate harden-key-lifecycle-and-logging --type change --strict`.
