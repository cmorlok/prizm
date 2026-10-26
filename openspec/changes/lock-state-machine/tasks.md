# Tasks

Lane B: challenge the design first, write a failing test for each transition (§IV), mandatory
security review, rig check for the server interaction (token refresh).

## 0. Checkpoint

- [x] 0.1 A fresh agent challenges proposal, design and spec (gaps, contradictions, untestable requirements); fix the change request first. Done 2026-11-01: 15 findings (4 high), all adopted (closed gate during teardown, API client refresh, sync on the flow token, tokens on vault states, `isFlowRunning`, Swift isolation, no re-arm, enrollment writers, zeroing, mapping, spec scenarios, tasks); finding 7 decided as keychain kept after a lock, nothing written after a sign-out.
- [x] 0.2 Decide design Open Questions 1 and 2 (with `session-lifecycle`): decided 2026-11-01, design D3 and D10.

## 1. Gate

- [ ] 1.1 Failing tests: `SessionGateImpl` (begin/isCurrent/end/open, closed gate hands out stale tokens, concurrent access); lock, system lock and sign-out end the gate before their first await and open it as the teardown's last step on every path; a sign-in works after each (design D1, Risks).
- [ ] 1.2 `SessionGate` + `FlowToken` (Domain, `nonisolated`, Sendable), `SessionGateImpl` (Data, `Mutex`), wired in `AppContainer`, `RootViewModelDependencies`, `MockRootDependencies`; `RawCipherStore` and `VaultKeyCache.record(_:for:ifCurrent:)` use the gate token; `RawCipherStore`/auth layer no longer end anything (design D1).

## 2. Flows

- [ ] 2.1 Failing tests, then fix: view models take tokens at the first step and later steps reuse them (two-factor, enrollment confirm/dismiss, the sync after them); `LoginUseCase`, `AuthRepository`, `EmbeddedBiometricUnlock` (stays in Data: `LAContext`) take `flow:`; `MockAuthRepository` and other mocks updated; `AuthRepositoryImpl` refuses keys, `setAccessToken`, server setup, the pending two-factor step, enrollment and `.vaultDidUnlock` for a stale token; `lockEpoch` and `UnlockUseCaseImpl` removed; the Settings toggle takes a token (design D2; gaps 3, 4).
- [ ] 2.2 Failing tests, then fix: `refreshAccessToken` returns tokens without storing them; after a sign-out nothing is written (keychain, API client), after a lock only the keychain; `signOut()` clears the API client's token and base URL (design D3; gap 3).
- [ ] 2.3 Failing tests, then fix: `unlockVM.end()` invalidates `biometricContext`, closes the sheet and blocks re-arming, retry and actions; `loginVM.endFlow()` (design D1, D4).
- [ ] 2.4 Failing tests, then fix: `isFlowRunning` (Touch ID, refresh, enrollment, sync); `canLock` adds `.totpPrompt` and `isFlowRunning`; `lockForSystemEvent()` for the three observers applies on an idle unlock screen; ⌘L there stays a no-op (design D5; gap 1).
- [ ] 2.5 Failing tests, then fix: a lock between the sync's last lock check and `VaultKeyCache.populate` or `OrgKeyCache.replaceAll` leaves both caches empty and zeroes the refused keys (design D8; gap 6).
- [ ] 2.6 Failing tests, then fix: a password-history read or attachment download/conversion whose keys were copied before a lock returns nothing once the lock started; no file remains after the sweep (design D8; gap 7).
- [ ] 2.7 Failing tests, then fix: a lock always creates a new unlock view model; `showVaultIfUnlocked` checks the view model's `isFlowCurrent` when the state arrives and after its await, ignores a stale flow; a stale login state does not replace the unlock screen (design D6, D7; gap 2).

## 3. UI

- [ ] 3.1 Failing tests, then fix: enrollment sheet closes on lock and is offered again; no stale "Syncing…"; "Sign in with a different account" disabled and the Touch ID badge hidden while `isFlowRunning` (design D6, D9; gap 5).
- [ ] 3.2 Hand check (Christian): Touch ID unlock + sleep; enrollment sheet + ⌘L; VoiceOver reads the disabled actions.

## 4. Release

- [ ] 4.1 Remove the guards of `lock-during-unlock-sync` that the gate replaces; its tests still pass or are rewritten to the new rule with the reason (design Risks).
- [ ] 4.2 Rig check against Vaultwarden 1.37.4: an unlock whose token refresh is held open by the rig's delay (`chore/rig-delay`); sign out during it, then keychain and API client hold no token; lock during it, then no keys and the keychain holds the refreshed tokens.
- [ ] 4.3 Security review.
- [ ] 4.4 CHANGELOG.
- [ ] 4.5 `openspec validate lock-state-machine --type change --strict`; replace the "TBD" Purpose of `session-lock-state` at archive.
