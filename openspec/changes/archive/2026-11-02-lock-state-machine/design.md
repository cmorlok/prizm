# Design

## Context

`lock-during-unlock-sync` (archived 2026-10-26) added, in this order:
- D1: only the current unlock view model drives the screen (`switchToLatest`).
- D2: the vault is shown only if keys are loaded, no lock is tearing down and none ran since the
  flow started; keys a stale flow loaded are torn down unless the vault is shown or a flow runs.
- D4: a lock applies during the sign-in (`.loading`).
- D5: flows started before a lock (`loginFlowStart`, `unlockFlowStart`) change nothing afterwards; a
  lock during an unlock keeps that unlock view model.
- D6: `AuthRepositoryImpl.lockEpoch`: a login or unlock that started before a lock or sign-out loads
  no keys; a lock discards a pending two-factor step.

Today several counters answer "did a lock happen since this started?", each bumped at a different
moment (code read 2026-11-01 on develop 9316c025):

| Counter | Where | Bumped |
|---|---|---|
| `lockGeneration`, `loginFlowStart`, `unlockFlowStart`, `isLocking` | `RootViewModel` (`PrizmApp.swift:298-303`) | synchronously in `lockVault()`/`signOut()`; flow starts noted when `.loading` reaches `handle…Flow`, after a main-queue hop |
| `lockEpoch` | `AuthRepositoryImpl.swift:89` | in `lockVault()`/`signOut()` of the auth layer, which `RootViewModel` calls inside a `Task`, so after a hop; a login reads it only in `loginWithPassword`, after the server setup was awaited |
| generation | `RawCipherStore.swift:68` (`Mutex`) | in `VaultRepositoryImpl.clearVault()`, which runs after `authRepo.lockVault()` |
| `generation` | `VaultKeyCache.swift:59` | in `clear()`; `populate(sources:)` ignores it |

Every gap of the proposal is a window between two of these moments:
- Gap 1: a Touch ID unlock has no `.loading`, so `canLock` is false and the lock is ignored.
- Gaps 2 and 4: a flow's start is seen by the auth layer later than by `RootViewModel`, so
  `showVaultIfUnlocked` guesses whose keys are loaded and may tear down a newer session's keys.
- Gap 3: the token refresh writes to the keychain after `await apiClient.refreshAccessToken`, with
  no check (`AuthRepositoryImpl.swift:478-482`, `:727-731`, `:798-801`), and the API client
  stores the new access token itself (`PrizmAPIClient.swift:1393`).
- Gap 6: the sync checks `ensureStillUnlocked` and writes the key caches on the next actor hop
  (`SyncRepositoryImpl.swift:192-193` org keys, `:286-287` item key sources). The org key cache has
  the same window as the item key cache (found 2026-11-01, not in the original proposal).
- Gap 7: `clearVault()` invalidates the store only after `authRepo.lockVault()` returned
  (`PrizmApp.swift:632-633`), so a decrypting read checks a token that is still current.

## Goals / Non-Goals

**Goals**
- After any lock or sign-out, no keys, decrypted data or tokens from a flow that was running remain
  or are written, on any path.
- A newer legitimate session is never torn down by an older flow.
- The lock applies in every state in which keys can be loaded.

**Non-Goals:** see proposal.md. Also: no `SessionState` enum replacing `RootViewModel.Screen` (D10).

## Decisions

### D1. One session gate: closed by the lock, opened by its teardown

A `SessionGate` (Domain protocol, Foundation only) with a `FlowToken` (an opaque value):
- `begin() -> FlowToken`: while the gate is open, the token of the current epoch; while it is closed,
  a token that is never current;
- `isCurrent(_ token: FlowToken) -> Bool`;
- `end()`: closes the gate and starts a new epoch, so every token handed out before is stale;
- `open()`: opens the gate again (the new epoch's tokens become available).

Swift 6: the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
(`project.pbxproj:1729/1788`), so the types are declared `nonisolated protocol SessionGate:
Sendable`, `nonisolated struct FlowToken: Hashable, Sendable` and `nonisolated final class
SessionGateImpl` (Data) over a `Mutex`, as `VaultSessionToken` (`VaultRepository.swift:145`) and
`RawCipherStore` do today. All four calls are synchronous and callable from any actor.

It replaces: `RootViewModel.lockGeneration`, `loginFlowStart`, `unlockFlowStart`, `isLocking`;
`AuthRepositoryImpl.lockEpoch`; the source of `RawCipherStore`'s generation (`currentGeneration()`
returns `gate.begin()`); `VaultKeyCache.generation` (`record(_:for:ifGeneration:)` becomes
`record(_:for:ifStillCurrent:)` with the gate's check). `VaultSessionToken` becomes `FlowToken`.
`TempFileManaging.sweepGeneration` stays: it fences the temp folder against the sweep, a different
event than the lock (the sweep runs inside the teardown), and is tested as such.

**Who ends and opens:** only the initiator of a lock or sign-out calls `end()`, as its first
statement, synchronously on the main actor (`RootViewModel.lockVault()`, `lockForSystemEvent()`,
`signOut()`, and `UnlockViewModel.signInWithDifferentAccount()` through `RootViewModel`).
`AuthRepositoryImpl.lockVault()`/`signOut()`, the record store and the key caches do not touch the
gate, so no other caller of `clearVault()` can leave it closed (`RawCipherStore.invalidate()` is a
DEBUG test seam that models the lock's first step). The teardown calls `open()` as its last step, right before it
creates the new unlock view model or shows the login screen. Between `end()` and `open()` every
`begin()` is stale, so nothing that starts during the teardown (a re-armed Touch ID, an Enter on
the old unlock screen, a lazy read of a token in the Data layer) can pass a check.

Right after `end()`, still in the same turn, the old flows are ended: `unlockVM?.end()` (invalidates
`biometricContext`, closes the enrollment sheet, and blocks `unlock()`, re-arming and the
enrollment actions from then on) and `loginVM.endFlow()` (cancels a pending two-factor prompt and
sets `.login` without a message).

### D2. Every flow takes its token at its first step

The view model takes `gate.begin()` synchronously in the action, before its `Task`:
`LoginViewModel.signIn()`; `UnlockViewModel.unlock()`; `unlockWithBiometrics()`; arming of the
embedded Touch ID view (`triggerEmbeddedBiometricIfAvailable()`, `rearmBiometrics()`); the Settings
toggle `BiometricUnlockToggleViewModel` when enabling. Later steps of the same flow reuse that token
and never take a new one: `submitTOTP` uses the sign-in's token (the pending two-factor step stores
it, and `loginWithTOTP` loads keys under it); `confirmEnrollBiometric()` and
`dismissEnrollmentPrompt()` and the sync after them use the unlock's token.

The token travels down: `LoginUseCase.execute(…, flow:)`, `completeTOTP(…, flow:)`,
`AuthRepository.loginWithPassword(…, flow:)`, `loginWithTOTP(…, flow:)`,
`unlockWithPassword(_:flow:)`, `unlockWithBiometrics(flow:)`,
`EmbeddedBiometricUnlock.unlockWithBiometrics(context:flow:onAuthenticated:)` (`onAuthenticated`
reports the accepted finger before any key loads, D5), `enableBiometricUnlock(flow:)`,
`setServerEnvironment(_:flow:)`, and the sync that ends the flow: `SyncUseCase.execute(flow:)` →
`SyncRepository.sync(flow:)` (D8). The view models check the flow token right before they start the
sync and again before they report the vault. `UnlockUseCaseImpl` is constructed
but never used (`AppContainer.swift:185`; the unlock view model calls the repository): it gets no
`flow:` and is removed as dead code. `EmbeddedBiometricUnlock` stays in Data although Presentation uses it
(`Data/Repositories/EmbeddedBiometricUnlock.swift:10`): it carries an `LAContext`, which the Domain
layer cannot name (Foundation only); the protocol's own comment records that choice.

For a stale token the auth layer refuses: loading vault keys (refused keys are zeroed; keys a lock
hit while loading are unloaded, as today); `apiClient.setAccessToken` and `setBaseURL`/the server
environment of the flow; the pending two-factor step; enrolling Touch ID; posting `.vaultDidUnlock`
(`AuthRepositoryImpl.swift:503-505, 739-741, 810-812`). The view models publish nothing for a stale
flow, except the login view model, which `endFlow()` already set to `.login` (D1). A late result
changes the login screen only while its flow is still the view model's latest sign-in, so it never
ends a sign-in the user started after the lock (review C2).

### D3. Tokens from a refresh: refused after a sign-out, kept after a lock

`PrizmAPIClient.refreshAccessToken` stores the new access token itself (`PrizmAPIClient.swift:1393`),
which no token check above it can fence. It changes to return the tokens without storing them; the
auth layer installs them (`setAccessToken`) and writes the keychain
(`AuthRepositoryImpl.swift:478-482, 727-731, 798-801`) only after its checks, with no await between
check and keychain write.

The check differs by event, because a lock keeps the account signed in:
- after a **sign-out** (a separate `accountEpoch` in the auth layer, bumped by `signOut()` before
  its deletes, read when the flow starts): nothing is written, neither keychain nor API client;
  `signOut()` also clears the API client's token and base URL;
- after a **lock**: the keychain receives the refreshed tokens (the server may have rotated the
  refresh token, and dropping it would sign the user out later), but the API client gets no access
  token and no keys are loaded. `lockVault()` itself clears the API client's token, so no bearer
  token stays in the network layer while locked (review C3).
- if the stored account changed during the refresh with no lock or sign-out (the flow is still
  current), the unlock fails with `accountChangedWhileUnlocking` and unloads the keys it loaded:
  no teardown would (review C8).

The refresh and a running sync are not cancelled; they finish and their writes are refused (Open
Question 2, decided). How refresh works during a session stays `session-lifecycle`'s.

### D4. Touch ID: disarmed by the lock, no re-arm from an ended view model

`unlockVM.end()` invalidates the current `biometricContext` (`LAContext.invalidate()`). An ended
view model never re-arms or re-triggers: the embedded path's `default:` re-arm
(`UnlockViewModel.swift:173-175`) and the non-embedded retry on `errSecUserCanceled` (`:134-139`,
mapped from `.appCancel`/`.systemCancel` at `AuthRepositoryImpl.swift:685-688`) check `isEnded`
first. The non-embedded `unlockWithBiometrics()` creates its own context in `readBiometric(key:)`,
which cannot be invalidated from outside; it is fenced by its token only (documented in the code).

### D5. A lock applies in every state in which keys can be loaded

`UnlockViewModel.isFlowRunning` is true from the moment a flow took its token (password unlock,
Touch ID success, reported by `onAuthenticated` before any key loads) through the token refresh, key load, the enrollment sheet and the sync, until the
vault is shown or the flow failed. `canLock` = vault or syncing shown, `.loading`, `.totpPrompt`
(new: today a lock on the two-factor prompt is ignored), or `unlockVM.isFlowRunning`. The Lock
Vault menu item and ⌘L use `canLock` (`PrizmApp.swift:73`), so ⌘L on an idle unlock screen stays a
no-op and keeps a typed password.

The three system observers (`PrizmApp.swift:425-439`) call `lockForSystemEvent()`, which also
applies on an idle unlock screen: it runs the whole lock teardown (gate, old unlock view model and
its Touch ID context, `authRepo.lockVault()`, `clearVault()`, a new unlock view model), so a Touch
ID prompt armed before sleep cannot finish after it and nothing an unlock loaded just before stays
loaded (review S2).

### D6. The lock screen belongs to a new unlock view model

Every lock creates a new unlock view model in its teardown (today a lock during an unlock kept it,
D5 of `lock-during-unlock-sync`). The old one is ended (D1), so its sheet, progress text and
"Syncing…" are gone and `switchToLatest` drops what it still publishes. An enrollment of a stale
flow sets no "prompt shown" flag, so enrollment is offered again after the next unlock.

### D7. The vault is shown only for a current flow

States reach `RootViewModel` after a main-queue hop (`receive(on:)`, `PrizmApp.swift:397/406`), so a
flow can be current when its view model publishes and stale when `RootViewModel` handles it. Both
view models expose `isFlowCurrent` (their flow token is current and, for the unlock screen, it was
not ended). `showVaultIfUnlocked`:
- stale flow, or a lock's teardown running: does nothing; the lock owns the screen (no
  `showLockedScreen()`, which would replace the unlock view model a newer flow is using);
- current flow: awaits `isVaultUnlocked`, checks `isFlowCurrent` again, and in the same turn calls
  `transitionToVault`; if the vault is not unlocked, shows the lock screen.
The teardown of keys "a stale flow still loaded" goes: a stale flow never loads keys (D2). A login
flow state is applied only while the screen belongs to the login flow (`.login`, `.loading`,
`.totpPrompt`; the sign-in syncs behind its loading screen), so a stale `.login` cannot replace the
unlock screen.

### D8. Sync writes and decrypting reads are fenced by the gate

- The sync that ends a sign-in or unlock runs with that flow's token, so a flow that a lock overtook
  before its sync began writes nothing, also when the gate opened for a new session meanwhile
  (review C5). A sync without a flow (manual, after a conflict) takes `begin()` at its start;
  between `end()` and `open()` that token is stale, so a sync that starts during a teardown writes
  nothing.
- `VaultKeyCache.populate(sources:ifCurrent:)` and `OrgKeyCache.replaceAll(with:ifCurrent:)` check
  the token inside the cache actor, in the same turn as the write (gap 6). A refused write zeroes
  the keys it was given.
- On-demand decryption reads its token at its start and checks it right before decrypting and before
  returning: `VaultRepositoryImpl.passwordHistory(itemId:)` (gap 7), the attachment download and
  conversion in `AttachmentRepositoryImpl`/`VaultKeyServiceImpl`. A decryption already running when
  the lock comes finishes on its own copy of the key, and its result is dropped. The repository's
  item cache writes use the same token. An opened attachment is still fenced against the sweep by
  `sweepGeneration` (D1).

### D9. UI follows the flow

While `unlockVM.isFlowRunning`, "Sign in with a different account" is disabled and the Touch ID
badge is hidden with its context invalidated (gap 5), for password and Touch ID unlocks alike; a
failed password unlock re-arms Touch ID. A second unlock while one runs is ignored (review C10),
and a replaced unlock view model is always ended, also by overlapping locks (review C6). The menu's
"Sign Out…" stays available
(it is the user's way out and is itself a lock-like event that ends the gate).

### D10. No separate state enum (deviation from the proposal)

The proposal sketched a `SessionState` enum owned by `RootViewModel` or a `SessionController`.
With D1–D9 validity has one source (the gate), and `RootViewModel.Screen` already lists the screens;
a second enum would duplicate `Screen` (Constitution §VI). Owner: `RootViewModel` (Open Question 1,
decided).

## Risks / Trade-offs

- **[Medium] Broad change to the flow code.** → The 35 tests of `RootViewModelLockTests` (23 plus
  the 12 of `RootViewModelLockDuringSyncTests`) and the lock tests of `KeyLifecycleTests` stay as
  the regression baseline; a test that encodes a replaced mechanism (the stale-keys teardown, the
  kept unlock view model, `testLockVault_noOpWhenUnlock`) is rewritten to the new rule, with the
  reason in the test.
- **[Medium] A gate left closed** would block every later flow. → `open()` is the teardown's last
  step on every path (lock, sign-out, errors), and a test checks that a sign-in works after each.
- **[Low] Keychain tokens refreshed after a lock are kept** (D3). The account is still signed in,
  so the keychain held valid tokens anyway; keys and the API client stay empty.
- **[Low] A system lock on an idle unlock screen clears a half-typed password** (fresh view model).
- **[Low] A stale flow's undo is not scoped to that flow** (review S-L2, accepted). When the check
  right after loading keys or installing the access token fails, the flow unloads the keys or clears
  the token without checking whose they are by then. A newer session would have to finish a whole
  teardown and unlock (key derivation, network) inside the one queued main-actor continuation
  between the install and that check. If this ever becomes reachable, the fix is an install-owner
  token in the crypto service and the API client.

## Open Questions

None. Decided 2026-11-01:
1. Owner: `RootViewModel`, with the gate as the shared part (D10).
2. Token refresh during an unlock: not cancelled; after a sign-out nothing is written, after a lock
   only the keychain keeps the rotated tokens (D3).

## Review

- **Spec challenge** (2026-11-01, fresh agent, before code): 15 findings (4 high), all adopted.
- **Security review and code review** (2026-11-01, fresh agents in their own worktrees, read-only):
  security 1 high (Release build: `AppContainer.sessionGate` declared inside `#if DEBUG`),
  1 medium and 4 low; code review 1 high, 5 medium and 8 low. Both found the same main bug: the
  embedded Touch ID unlock counted as running only after its token refresh, so sleep or ⌘L in that
  window left the keys loaded behind the lock screen. Fixed by `onAuthenticated` and the full
  teardown in `lockForSystemEvent()` (D5). All other findings were fixed with red/green tests;
  one low (S-L2) is accepted under Risks. Findings, fixes and runs: commit messages of 9886a4b1,
  b9040894, 4eaa6700, 62f23191, e6696c5b, e6b6ecb2, b9b75044.
- **Pre-existing, separate change**: the Release configuration did not compile on `develop`
  (`UITestFixtures` used outside `#if DEBUG` since `fix-website-icons-privacy`), fixed in
  `fix-release-build`.
- **Rig check** (task 4.2) on Vaultwarden 1.37.4, 20261101T103026Z: all six checks pass.
- **UI run** 20261101T103325Z (Login, Unlock, BiometricUnlock, BiometricEnrollment, VaultBrowser,
  EditItem journeys): 52 tests, 37 pass, 15 standing skips (simulated Touch ID, save backend,
  real server), 0 fail.
- **Hand checks** (task 3.2, Christian, 2026-11-02): Touch ID + sleep and VoiceOver confirmed; the
  enrollment sheet + ⌘L is covered by unit tests only (it needs an account without Touch ID).
- **/opsx:verify** (2026-11-02): 4/4 requirements, 16/16 scenarios covered; two scenarios had no
  direct test and got characterisation tests (42fb9452). SECURITY.md describes the lock of running
  flows (edd9bb48).
- **Unit tests**: every commit builds and passes on its own (20261102T125837Z … 130310Z); tip 1648.
