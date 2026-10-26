# Proposal

## Why

**Criticality:** P1 (High: security, Constitution §III)
**Origin:** the verification rounds of `lock-during-unlock-sync` (fix/016, 2026-10-26). That change
made a lock during unlocking, signing in or the first sync stay in effect, with guards in two layers
(design D1–D6 there). Each verification round still found another path, because the lock interacts
with every flow: sign-in, two-factor, password unlock, Touch ID unlock, the Touch ID enrollment
prompt, sign-out, token refresh and sync. The remaining gaps are narrow, but they are about keys and
tokens, and patching them one by one does not converge. They need one explicit model.

**Known gaps after `lock-during-unlock-sync`:**
1. **Touch ID unlock ignores a lock.** A Touch ID unlock never shows an in-progress state, so a lock
   from the Touch ID prompt until the unlock ends (including the token refresh, up to the request
   timeout) is ignored, and the vault opens. This diverges from the `vault-lock` requirements (sleep,
   screensaver, screen lock).
2. **Touch ID on an unlock view model kept by a lock.** After a lock during a password unlock, the
   kept view model can start a Touch ID unlock; when that ends before the password unlock's refusal
   arrives, its legitimate keys are treated as stale and torn down (the user is locked again after
   unlocking).
3. **Tokens written back after a sign-out.** "Sign in with a different account" (or Sign Out) during
   an unlock's token refresh deletes the tokens; when the refresh returns, the unlock writes the new
   access and refresh tokens back to the keychain for the signed-out account.
4. **Flow starts the auth layer does not see.** A login's lock count is taken in
   `loginWithPassword`, after `LoginUseCase` has already awaited the server setup; the presentation
   layer compensates (fix/016 D2), but the auth layer cannot refuse such a flow itself.
5. **UI details.** The Touch ID enrollment sheet stays over the lock screen after a lock (accepting
   it then fails silently and marks the prompt as shown); a kept unlock view model shows its own
   "Syncing…" text inside the unlock screen until its stale sync ends; "Sign in with a different
   account" and the Touch ID badge stay active while an unlock runs.
6. **Sync writes keys after its lock check.** The sync checks that the vault is still unlocked
   (`ensureStillUnlocked`) and then, in a separate step, replaces the item key cache
   (`VaultKeyCache.populate`, `SyncRepositoryImpl`, phase 2d). A lock between the two leaves the new
   key sources, item keys included, in the cache the lock just cleared, until the next sync replaces
   them. Pre-existing for item keys; `fix-org-attachment-key` (fix/027) added the key sources of
   every item to the same write. The check and the write need to be one step (the cache refusing a
   write for a stale flow token, as for the auth layer).
7. **Reads that decrypt after the keys are gone.** `clearVault()` bumps the record-store
   generation only after `lockVault()` has returned, so a read that copied the keys before the lock
   and passes its generation check in between still decrypts after the lock. Found by the security
   review of `password-history` (fix/037): opening the history sheet and locking at once can decrypt
   the entries for a few milliseconds (the sheet itself dismisses synchronously on lock). The lock
   needs to invalidate readers in the same step that removes the keys.

## What Changes

- **One session gate** (`SessionGate`, Domain protocol, Data implementation) replaces the lock
  counters of today (`RootViewModel` lock generation and flow starts, `AuthRepositoryImpl.lockEpoch`,
  the record-store and key-cache generations). A lock or sign-out closes it as its first step,
  before any await; its teardown opens it again as its last step, so nothing started in between
  counts.
- **Every flow carries a token from its first step** (sign-in, two-factor, password unlock, Touch ID
  arming), taken synchronously in the view model; later steps (two-factor, enrollment, the sync)
  reuse it. The auth layer refuses keys, the API client token, enrollment and the unlock
  notification for a stale token; after a sign-out it also writes no keychain tokens. The view
  models publish nothing for it. No outcome-based guessing about whose keys are loaded.
- **Results are dropped, not cancelled:** a token refresh or sync that was running finishes and its
  writes are refused (the API client no longer stores a refreshed token itself); an armed Touch ID
  context is invalidated (`LAContext.invalidate()`) and an ended unlock view model never re-arms.
- **A lock always applies** while any sign-in, two-factor step or unlock runs, Touch ID and the
  enrollment sheet included; system triggers also renew an idle unlock screen.
- **Sync key-cache writes and decrypting reads** check the token in the same step as the write or
  before and after decrypting (gaps 6 and 7; gap 6 also covers the organization key cache).
- **UI follows the flow:** a lock always gives the unlock screen a new view model (enrollment sheet
  closed, no stale progress); competing actions are disabled while an unlock runs.

## Capabilities

### New Capabilities
- `session-lock-state`: one model for lock, sign-out and the sign-in and unlock flows.

### Modified Capabilities
- None. `vault-lock` keeps its triggers; the new capability states what a lock does to running
  flows.

## Non-Goals

- Inactivity timeout (`vault-timeout`, which adds a trigger to this model and should follow it).
- Token refresh during the session and its error handling (`session-lifecycle`). This change only
  makes sure no flow writes tokens after a lock or sign-out.

## Dependencies

- **After:** `lock-during-unlock-sync` (its tests are the regression baseline).
- **Before:** `vault-timeout`.
- **Coordinate with:** `session-lifecycle` (both touch the token refresh path).

## Lane

Lane B (OpenSpec with checkpoints): a challenge of the design before coding, a mandatory security
review, and a test for each transition, including the races found in `lock-during-unlock-sync`.

## Impact

- **Presentation/App:** `RootViewModel` state handling, `LoginViewModel`, `UnlockViewModel`,
  `UnlockView` (enrollment sheet, badges).
- **Data:** `AuthRepositoryImpl` (flow tokens instead of the lock epoch, guarded token writes).
- **Domain:** `SessionGate` protocol and `FlowToken` (Foundation only).
- **Data:** also `RawCipherStore`, `VaultKeyCache`, `OrgKeyCache`, `SyncRepositoryImpl`,
  `VaultRepositoryImpl.passwordHistory`, `AttachmentRepositoryImpl`, `VaultKeyServiceImpl` (token
  checks), `PrizmAPIClient.refreshAccessToken` (returns tokens without storing them).
- **Removed:** `UnlockUseCaseImpl` (constructed, never used).
- **Security review:** yes.

## Estimate

About 3–5 ideal days, to be refined in the design checkpoint.
