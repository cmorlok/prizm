# Proposal

## Why

**Criticality:** P2 (Medium: security, §III)
**Findings:** `fix-ui-journey-findings` review (2026-10-25), "Out of scope, pre-existing: locking while
the unlock flow's sync runs; if that sync later reports success, the vault is shown again".
Decided 2026-10-26.

**A lock during the sync after unlocking or signing in can be undone.** ⌘L (or sleep, screensaver,
screen lock) works while the sync runs (`RootViewModel.isVaultUnlocked` includes `.syncing`). The lock
zeroes the keys and shows the unlock screen. When the interrupted sync then ends, the old flow still
reaches its last step:

- **Unlock flow:** `RootViewModel` subscribes to the unlock view model's state with
  `$unlockVM.compactMap { $0 }.flatMap { $0.$flowState }` (`PrizmApp.swift`, `subscribeToFlowStates`).
  `flatMap` keeps the subscription to the previous unlock view model after the lock creates a new
  one. The old view model's progress messages switch the screen back to "Syncing…", and its final
  `.vault` shows the vault browser. `UnlockViewModel.performSync` ends in `.vault` even when the
  sync failed; since `fix-empty-trash` a sync interrupted by a lock fails on purpose.
- **Login flow:** `LoginViewModel` publishes `.vault` after its sync the same way, and
  `handleLoginFlow` shows the vault.

The vault browser is then shown with no keys and an empty store. Nothing decrypted is exposed (the
lock cleared it), but the app claims to be unlocked: the lock screen is gone, ⌘L is a no-op because
`isVaultUnlocked` is true, and the next actions fail with "vault locked" errors. A user who locked
the Mac sees an unlocked-looking Prizm when they come back.

### Origin of the current behaviour

- **Accidental.** `flatMap` was used to re-subscribe when the unlock view model is replaced; the
  old subscription's lifetime was not considered. The transition to the vault never checked that
  the vault is still unlocked.

## What Changes

- Only the current unlock view model drives the screen (`switchToLatest`); a view model replaced by
  a lock, or removed when signing out, no longer has any effect.
- The vault is shown only if the vault is still unlocked. A flow that ends after a lock leads to the
  unlock screen (or the login screen when no account is stored), for both the login and the unlock
  flow.
- `AuthRepository.isVaultUnlocked` tells the presentation layer whether keys are loaded.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `vault-lock`: a lock during a running sync stays in effect.

## Non-Goals

- Cancelling the running sync request. It ends on its own, and since `fix-empty-trash` it writes
  nothing after a lock.
- Idle timeout (`vault-timeout`).

## Impact

- **Domain:** `AuthRepository.isVaultUnlocked`.
- **Data:** `AuthRepositoryImpl.isVaultUnlocked` (reads `PrizmCryptoService.isUnlocked`).
- **Presentation/App:** `RootViewModel` subscription and vault transition.
- **Security review:** yes (lock state, §III).

## Estimate

| Step | Scope | Estimate |
|---|---|---|
| 1 | Failing tests for both flows | 0.25 d |
| 2 | Subscription and transition guard | 0.25 d |
| 3 | Review, CHANGELOG | 0.25 d |
| **Total** | | **0.75 d** |
