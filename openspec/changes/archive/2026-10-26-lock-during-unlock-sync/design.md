# Design

## Context

- `RootViewModel.lockVault()` runs while `screen` is `.vault` or `.syncing`, clears the vault browser,
  zeroes the keys through `authRepo.lockVault()`, clears the store and the clipboard, and then
  creates a new `UnlockViewModel` and shows `.unlock` (or `.login` without a stored account).
- `subscribeToFlowStates()` subscribes to `loginVM.$flowState` for the app's lifetime and to the
  unlock view model's `$flowState` through `$unlockVM.compactMap { $0 }.flatMap { $0.$flowState }`.
- `UnlockViewModel.performSync()` and `LoginViewModel` set `.vault` after the sync, also when it
  failed (a failed sync after unlock is non-fatal by design).
- Since `fix-empty-trash`, `SyncRepositoryImpl` throws `vaultLocked` instead of writing when the vault
  locked during the sync.

## Decisions

### D1. Only the current unlock view model counts

`$unlockVM.map { $0?.$flowState.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher() }.switchToLatest()`.
Replacing or removing the unlock view model cancels the subscription to the old one, so its late
progress messages and its `.vault` are dropped. `lockVault()` without a stored account sets
`unlockVM = nil` as `signOut()` does.

### D2. The vault is shown only while the vault is unlocked

`.vault` from either flow calls `showVaultIfUnlocked(caller:)`: it checks
`await authRepo.isVaultUnlocked` and only then runs the existing `transitionToVault`. Otherwise it
logs the dropped transition and shows `.unlock` (with a new unlock view model) or `.login`. This
also covers the login flow, whose view model is never replaced, and any later path that reaches
`.vault`.

After the await, three conditions must hold: the keys are loaded, no lock is still tearing down
(`isLocking`, set by `lockVault()` until its task ends) and no lock ran since the `.vault` was
received (`lockGeneration`). `lockVault()` returns before its teardown finishes, and a `.vault`
already queued on the main queue can arrive in that window, so the key check alone is not enough.
If the keys are loaded but a lock ran (a sign-in whose key derivation ended after the lock), they
are torn down again before the lock screen is shown. The lock also clears the vault browser a
second time at its end, so nothing shown during the teardown stays in memory.

### D4. A lock applies during the sign-in sync

The login flow shows `.loading` while it derives keys and runs its first sync. `canLock` accepts
`.loading` as well as `.vault` and `.syncing`, for `lockVault()` and the Lock menu item. A lock
before the keys exist is harmless: D2 tears down the keys the sign-in loads afterwards.

**Rejected alternative:** cancel the flows' tasks on lock. The view models do not keep their tasks,
and a cancelled sync would still need D2 to end on the right screen.

### D3. `isVaultUnlocked` comes from the crypto service

`AuthRepository.isVaultUnlocked` is `get async` and returns `PrizmCryptoService.isUnlocked`, the
single source of truth that `lockVault()` resets. No new state is kept in the view model.

## Risks / Trade-offs

- **[Low] One more actor hop before the vault appears.** → The transition already defers work to the
  next run-loop turn.

## Open Questions

_None._
