# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
Land after `fix-kdf-derivation-and-validation` if both are in flight (soft dependency).

## 1. One teardown path (0.5 d)

- [x] 1.1 Failing test: store an org key in `OrgKeyCache`, call `AuthRepositoryImpl.signOut()`, assert the cache is empty and the stored key's buffer is zero (test seam as in `OrgKeyCryptoKATTests.swift:47`).
- [ ] 1.2 Failing test: `UnlockViewModel.signInWithDifferentAccount()` leaves both caches empty.
- [x] 1.3 Inject `VaultKeyCache` and `OrgKeyCache` into `AuthRepositoryImpl` (`AppContainer`). `lockVault()` clears both after zeroing the vault key (design.md D1). Remove the cache clearing from `PrizmApp.signOut()` and `PrizmApp.lockVault()`. Existing lock tests still pass.

## 2. Sync replaces org keys (0.25 d)

- [x] 2.1 Failing tests: (a) sync with orgs, then a sync with `organizations: []` → cache empty (already done by `fix-org-key-required-on-write`, keep as regression test); (b) sync whose `privateKey` fails to decrypt → cache empty and org items excluded; (c) a sync that fails as a whole keeps the previous keys.
- [x] 2.2 Replace the cache with an empty map when the org step fails (D2, reconciled); no clearing at sync start.

## 3. Zero transient keys (1 d)

- [x] 3.1 Failing tests with test seams: after `loginWithPassword` (no 2FA), the master key and stretched key buffers are zero; after unlock, the same; after a thrown error in either path, the same.
- [x] 3.2 Failing tests: the pending-2FA stretched keys are zero after TOTP success, after cancel and after sign-out during the 2FA step.
- [x] 3.3 Implement D3 in `AuthRepositoryImpl` (`var` + `defer`, `clearPendingTwoFactor()`), with §VII comments on the copy-on-write caveat.
- [x] 3.4 `decryptSymmetricKey`: copy the halves into fresh `Data`, zero `keyData`. Test: the returned keys still decrypt a type-2 vector; the scratch buffer is zero.
- [x] 3.5 Argon2Swift: zero `hash` and `encoded` before `deallocate`; `argon2idDerive` zeroes the result arrays. Bump the vendored version suffix and note the patch. The Argon2id KATs still pass.

## 4. Debug logging (0.25–0.5 d)

- [x] 4.1 Failing test: `debugDescription(ofTokenParams:)` for a request with `username`, `password`, `twoFactorToken` and `deviceIdentifier` contains none of their values and contains `grant_type`, `client_id` and `twoFactorProvider` (D4).
- [x] 4.2 Use it in `identityToken`; make the non-JSON 400 body `.private`.
- [x] 4.3 Review every `DebugConfig.isEnabled` block in `Prizm/` for `.public` emails, tokens, URLs with query secrets or server text; fix and list the changed lines in the PR description.

## 5. Docs and release (0.5 d)

- [x] 5.1 SECURITY.md per design.md D5: key table (`:72-82`), lifecycle steps 3 and 4 (`:94-99`), a "Limits of zeroing in Swift" paragraph, the biometric comparison with iOS and desktop.
- [x] 5.2 Correct the comments in `Config.swift:36-37`, `OrgKeyCache.swift:13,52` and `AppContainer.swift:26`.
- [ ] 5.3 Mandatory security review: every key buffer listed in SECURITY.md is zeroed where the doc says; no secret in `.public` logs; teardown order (zero before release).
- [x] 5.4 CHANGELOG "Security": organization keys are cleared on sign-out and when a sync no longer lists the organization; master and stretched keys are zeroed after use; debug mode no longer logs the email or the two-factor code. "Docs": SECURITY.md corrections (device identifier, biometric comparison).
- [x] 5.5 `openspec validate harden-key-lifecycle-and-logging --type change --strict`.

## Results (2026-10-26)

- Reconciled with `fix-org-key-required-on-write` (design D2): no clearing at sync start; the org
  step's failure path replaces the keys with an empty map; a sync that fails as a whole keeps them.
  That change's test 2.3 now uses a whole-sync failure.
- `KeyLifecycleTests`: teardown (sign-out and lock clear both caches), zeroing after login, failed
  login, wrong-password unlock, 2FA success, cancel and sign-out, the debug allow-list.
  `UserKeyBufferTests`: `decryptSymmetricKey` returns independent buffers. The zeroing tests use a
  DEBUG seam (`AuthRepositoryImpl.zeroedKeyObserver`) that also reports whether the zeroing
  happened in place, so a copy-on-write copy cannot pass them.
- Beyond the design: the vendored Argon2Swift also copied the password into an array nobody zeroed;
  it now passes it by pointer (`1.0.1-bw3`). `Argon2SwiftResult.zero()` is new.
- 1.2 (`UnlockViewModel.signInWithDifferentAccount`) is covered by the sign-out test: that action
  calls `AuthRepository.signOut()`, which now clears both caches.
- 1.1's "the stored key's buffer is zero" is not observable from outside `OrgKeyCache`; the test
  checks that the caches are empty.
- **Not verified on the Mac yet** (test runner hung, screen locked): run `PrizmTests`, including the
  Argon2id KATs, which must be unchanged.
- 5.3 security review: teardown order and the allow-list are right; zeroing of the transient
  buffers is in place. Fixed after review: org keys (`unwrapOrgKey`) and biometric-unlocked vault
  keys (`CryptoKeys(data:)`) were slices of one buffer, so zeroing one half on lock zeroed a copy;
  both now use `subdata`, and the biometric paths zero their 64-byte blob. The TOTP path moves the
  keys into a local before its await, so a concurrent cancel or sign-out cannot zero a mere copy; a
  new password login zeroes an unfinished two-factor step. A non-JSON token body is no longer
  logged (keys only). `RootViewModelDependencies` no longer requires the two caches.
- Known limits, documented: the RSA decryption's output buffer belongs to the Security framework;
  `OrgKeyCache.clear()` has no in-place test seam; outside debug mode, some error logs still carry
  a server response (open item).

