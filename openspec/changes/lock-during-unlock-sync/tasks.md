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

