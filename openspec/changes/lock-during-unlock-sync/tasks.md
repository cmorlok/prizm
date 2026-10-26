# Tasks

Write a failing test first for each task (§IV).

## 1. Tests (0.25 d)

- [ ] 1.1 Failing test: an unlock view model replaced by a lock no longer changes the screen (late `.syncing` and `.vault`).
- [ ] 1.2 Failing test: `.vault` from the login flow while the vault is locked shows the unlock screen.
- [ ] 1.3 Failing test: lock without a stored account removes the unlock view model.
- [ ] 1.4 Test: the normal unlock and login flows still reach the vault.

## 2. Implementation (0.25 d)

- [ ] 2.1 `AuthRepository.isVaultUnlocked` (design D3), mock included.
- [ ] 2.2 Design D1 and D2 in `RootViewModel`.

## 3. Release (0.25 d)

- [ ] 3.1 Security review: no path shows the vault browser while the keys are cleared.
- [ ] 3.2 CHANGELOG "Fixed": locking Prizm while it syncs after unlocking or signing in no longer shows the vault again when the sync ends.
- [ ] 3.3 `openspec validate lock-during-unlock-sync --type change --strict`.
