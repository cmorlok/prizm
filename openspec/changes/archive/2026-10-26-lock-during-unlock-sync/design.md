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
(`isLocking`, set by `lockVault()` until its task ends) and no lock ran since the flow started
(`lockGeneration` compared with the flow's start). `lockVault()` returns before its teardown
finishes, and a `.vault` already queued on the main queue can arrive in that window, so the key
check alone is not enough.

If a lock ran since the flow started and keys are loaded, they either belong to a newer unlock or
to this flow, when its start reached the auth layer only after the lock (a lock during the
sign-in's server setup, before `loginWithPassword` takes its count; D6 cannot refuse those). The
rule: if a lock is still tearing down, the vault is already shown, or the other flow (the unlock
for a sign-in, the sign-in for an unlock) is still running or has just reached the vault, that
newer flow owns the screen and the keys, and this flow changes nothing. Otherwise keys are torn
down and the lock screen is shown. (An unconditional teardown here could lock a newer session, third verification W1; no
teardown left the case above open, final review 1a.) The lock also clears the vault browser a
second time at its end, so nothing shown during the teardown stays in memory.

### D3. `isVaultUnlocked` comes from the crypto service

`AuthRepository.isVaultUnlocked` is `get async` and returns `PrizmCryptoService.isUnlocked`, the
single source of truth that `lockVault()` resets. No new state is kept in the view model.

### D4. A lock applies during the sign-in sync

The login flow shows `.loading` while it derives keys and runs its first sync. `canLock` accepts
`.loading` as well as `.vault` and `.syncing`, for `lockVault()` and the Lock menu item. A lock
before the keys exist is harmless: the sign-in then loads no keys (D6).

**Rejected alternative:** cancel the flows' tasks on lock. The view models do not keep their tasks,
and a cancelled sync would still need D2 to end on the right screen.

### D5. Flows that started before a lock (added 2026-10-26, verification)

`RootViewModel` remembers `lockGeneration` when a sign-in or unlock starts (`.loading`). Such a flow
changes nothing after a later lock: its "Syncing…" is ignored, a two-factor prompt is cancelled
(`LoginViewModel.cancelTOTP()`, which discards the pending keys), and its `.vault` goes through D2
with the flow's start. `canLock` also accepts an
unlock in progress; the lock then keeps that unlock view model, so its end still reaches D2.

States reach `RootViewModel` through the main queue, so a lock can come before a flow's `.loading`
arrives. `lockVault()` therefore marks a running flow itself, and a late `.unlock` or `.login` only
clears the mark when it is still the view model's current state.

### D6. The auth layer refuses keys after a lock (added 2026-10-26, second verification)

The second verification found side paths where a flow that started before a lock still loaded its
keys afterwards: the Touch ID enrollment prompt after an unlock, an unlock view model dropped by
Sign Out or "Sign in with a different account", and the whole sync of a stale flow. Guarding each
path in the presentation layer kept opening new ones, so the check now sits where keys are loaded.
`AuthRepositoryImpl` counts locks and sign-outs (`lockEpoch`); every login and unlock captures the
count at its start, and `loadVaultKeys` refuses (and zeroes) its keys if a lock came since, or
unloads them if one comes while they are loaded; in both cases the flow fails with
`AuthError.lockedWhileUnlocking` ("Prizm was locked before it finished. Try again."). Keys unloaded
because a lock came while they were being loaded are zeroed in place, and a lock also discards a
pending two-factor step (its keys are zeroed; a login that reaches the two-factor step after a lock
keeps nothing). On success the caller's copy is dropped, so the crypto service holds the only
reference and a later lock zeroes the keys in place. A lock that comes after the keys are loaded
(for example during an unlock's token refresh) does not make the flow fail; D2 keeps the screen
locked and the lock zeroes the keys. D2 and D5 stay
as the screen-level guards; `signOut()` now also counts as a lock for them and clears the browser
again at its end.

**Known limit (divergence from the sleep, screensaver and screen-lock requirements):** a Touch ID
unlock never shows `.loading`, so `canLock` is false from the Touch ID prompt until the unlock ends,
including the token refresh, which can take until the request times out. A lock in that window is
ignored and the vault opens; no keys are loaded behind a lock screen. Follow-up: show `.loading`
during a Touch ID unlock.

**Other known limits (follow-ups):** a lock while the Touch ID enrollment sheet is shown keeps the
sheet over the lock screen (accepting it then fails silently and does not offer enrollment again);
an unlock view model kept by D5 shows its own "Syncing…" text inside the unlock screen until its
stale sync ends.

## Risks / Trade-offs

- **[Low] One more actor hop before the vault appears.** → The transition already defers work to the
  next run-loop turn.

## Open Questions

_None._
