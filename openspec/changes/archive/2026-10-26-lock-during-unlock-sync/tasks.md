# Tasks

Write a failing test first for each task (§IV).

## 1. Tests (0.25 d)

- [x] 1.1 Failing test: an unlock view model replaced by a lock no longer changes the screen (late `.syncing` and `.vault`).
- [x] 1.2 Failing test: `.vault` from the login flow while the vault is locked shows the unlock screen.
- [x] 1.3 Failing test: lock without a stored account removes the unlock view model.
- [x] 1.4 Test: the normal unlock and login flows still reach the vault.

## 2. Implementation (0.25 d)

- [x] 2.1 `AuthRepository.isVaultUnlocked` (design D3), mock included.
- [x] 2.2 Design D1 and D2 in `RootViewModel`.

## 2b. Added during verification (2026-10-26)

- [x] 2b.1 Design D5: flows that started before a lock change nothing afterwards.
- [x] 2b.2 Design D6: the auth layer refuses keys of a flow that started before a lock.

## 3. Release (0.25 d)

- [x] 3.1 Security review: no path shows the vault browser while the keys are cleared.
- [x] 3.2 CHANGELOG "Fixed": locking Prizm while it syncs after unlocking or signing in no longer shows the vault again when the sync ends.
- [x] 3.3 `openspec validate lock-during-unlock-sync --type change --strict`.

## Results (2026-10-26)

- `RootViewModelLockDuringSyncTests`: 6 tests. Without the `RootViewModel` change, 1.1, 1.2 and 1.3
  fail (checked on the Mac); with it, all 718 unit tests pass.
- Besides `isVaultUnlocked`, `showVaultIfUnlocked` compares a lock counter: `lockVault()` returns
  before its teardown finishes, so a flow ending in that window would still find the keys loaded.
- The mock auth repository now reports locked after `lockVault()` and unlocked after
  `unlockWithPassword`.
- Review (2026-10-26, task 3.1): the sign-in sync shows `.loading`, where a lock was ignored (the
  spec scenario could not hold) → design D4, `canLock`; a `.vault` already queued could win against
  the lock's teardown → `isLocking`, second `clearSession()`, keys torn down again (D2); the test now
  emits a late progress message; a race-free gate (`Mutex`) opened in `tearDown`; doc comments
  moved back to their declarations. The two new tests (`testVaultCheckOverlappingALock_…`,
  `testLockWhileSigningIn_isNotIgnored`) fail on the first version (checked); all 720 unit tests
  pass with the final one.

## Verification (2026-10-26, `/opsx:verify`)

- The two suggestions were fixed (design D5): after a lock during sign-in, a two-factor prompt or
  failure screen no longer replaces the lock screen, and a lock while the unlock derives keys is no
  longer ignored. The requirement and a new scenario cover both.
- Writing the test found a race: a late `.unlock` or `.loading` from the main queue could clear the
  lock's mark, and the vault opened after the lock (checked with probe tests on the Mac). Fixed in
  D5. New tests: `testLockDuringUnlockKeyDerivation_staysLockedAndTearsDown`,
  `testTwoFactorAfterALockDuringSignIn_isCancelled`.
- Unit tests: 726 passed on the Mac.

## Second verification (2026-10-26)

- Keys could still be loaded behind the lock or login screen by a flow that started before a lock
  (Touch ID enrollment prompt, an unlock dropped by Sign Out or "Sign in with a different account",
  the sync of a stale flow). Fixed at the source (design D6): `AuthRepositoryImpl` refuses keys
  after a lock. `KeyLifecycleTests.testLockDuringUnlock_loadsNoKeys` and
  `testSignOutDuringLogin_loadsNoKeys` fail without it (checked on the Mac).
- `signOut()` counts as a lock for running flows and clears the vault browser again at its end; the
  teardown in D2 also runs while a lock is still tearing down; "Sign in with a different account"
  clears the unlock flow's mark. New test `testUnlockAfterALock_reachesTheVault`.
- The main spec `vault-lock` said Lock Vault is disabled on the loading and unlock screens, which
  `canLock` no longer matches; the change now MODIFIES the four lock requirements.
- Accepted limit: a lock during a Touch ID unlock's brief key load is ignored (D6).
- Unit tests: 730 passed on the Mac.

## Third verification (2026-10-26)

- W1: the teardown in `showVaultIfUnlocked` could lock a newer session (lock during the sign-in
  sync, new unlock, then the old sign-in ends). Removed; D6 makes it redundant. New test
  `testStaleSignInEndingAfterANewUnlock_leavesTheNewSessionAlone`.
- W2: keys unloaded because a lock came while they were loaded are now zeroed in place
  (`testLockWhileLoadingKeys_unloadsAndZeroesThem`); refused keys too (assertion added).
- A lock discards a pending two-factor step in the auth layer, and a login that reaches the
  two-factor step after a lock keeps no keys. The message reads "Prizm was locked before it
  finished. Try again." (also shown on the login screen).
- The mock auth repository now refuses keys after a lock like the real one, so the RootViewModel
  tests run the real sequence.
- Known limits recorded in design D6: the Touch ID unlock window, the enrollment sheet after a lock,
  the "Syncing…" text of a kept unlock view model.
- Unit tests: 732 passed on the Mac.

## Final review (2026-10-26)

- 1a: removing the teardown left a path open: a lock during the sign-in's server setup, before the
  auth layer takes its count, let that sign-in load keys and data behind the lock screen. D2 now
  tears down keys after a lock unless the vault is shown or a sign-in or unlock is still running
  (`testStaleSignInWithKeysLoadedAfterTheLock_tearsThemDown`; the W1 test still passes).
- 2: after a successful load the caller's copy of the keys is dropped, so a later lock zeroes them
  in place.
- 4: tests for the two-factor protection: `testTwoFactor_lock_zeroesThePendingKeys`,
  `testTwoFactorChallengeAfterALock_keepsNoKeys`.
- 1b (Touch ID on a kept unlock view model), 3 (tokens written back after a sign-out during an
  unlock's token refresh), the Touch ID window and the UX details move to the change request
  `lock-state-machine` (Lane B), with 3 also relevant to `session-lifecycle`.
- Unit tests: 734 passed on the Mac.

## Last review (2026-10-26)

- 1c: a stale sign-in that ended without keys while a newer unlock derived keys replaced that
  unlock's view model; the unlock then loaded keys and data unseen behind a fresh lock screen. A
  stale flow now changes nothing while the other flow runs or has just reached the vault
  (`testStaleSignInEndingDuringANewUnlock_leavesItRunning`, fails on the previous code).
- `PrizmCryptoServiceImpl.unlockWith` zeroes keys it replaces instead of dropping them.
- Remaining items belong to `lock-state-machine` (change-request branch, Lane B).
- Unit tests: 735 passed on the Mac.

