# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies. Task 2.1 (purge guard) comes first and can merge on its own.

## 1. Confirm server behaviour (0.25 d)

- [ ] 1.1 On the rig (Vaultwarden 1.37.4) and Bitwarden self-hosted if available: `DELETE /api/ciphers` with `{"ids": [...]}` for two trashed personal items and one org item the user may not delete. Record in design.md, Context, the status code and which items remain. Never call `/ciphers/purge`, not even on the rig.

## 2. API call and purge guard (0.5 d)

- [x] 2.1 Failing guard test (design D5): the recording mock URL protocol fails any test whose request path ends in `/purge`; a source scan fails if `ciphers/purge` appears in `Prizm/` outside a warning comment. Fix the comment at `PrizmAPIClient.swift:1089`.
- [x] 2.2 Failing test: `permanentDeleteCiphers(ids:)` sends `DELETE /api/ciphers` with JSON body `{"ids": [...]}` and the bearer token.
- [x] 2.3 Implement it in `PrizmAPIClient`, with a §VII comment that names the purge endpoint and why it must not be used, with source references.

## 3. Repository and use case (0.5 d)

- [x] 3.1 Failing test (mock API): `emptyTrash()` (implemented as `VaultRepository.permanentDeleteItems(ids:)` plus `EmptyTrashUseCase`) sends only the ids of items with `isDeleted == true`, in chunks of 500; active items are never in a request.
- [x] 3.2 Failing test: after the delete calls (success or error), a sync runs and `EmptyTrashResult.remaining` is the trash count after that sync.
- [x] 3.3 Implement `VaultRepository.emptyTrash()`, `EmptyTrashUseCase` (Domain) and its Data impl; wire in `AppContainer`.

## 4. Trash UI (0.5 d)

- [x] 4.1 Failing view-model test: Empty Trash first syncs, then exposes the confirmation with the fresh count; a failed sync shows the D2 message and sends no delete.
- [x] 4.2 Add the toolbar button and confirmation (design D3) to `TrashView`, using the destructive style. Add `AccessibilityID.Trash.emptyTrashButton`.
- [ ] 4.3 VoiceOver: button label "Empty Trash"; result announcement (§VIII). XCUITest: trash with two items → Empty Trash → confirm → empty state shown.

## 5. Partial failure (0.25 d)

- [x] 5.1 Failing view-model test: `remaining > 0` shows the D4 message with the right count and singular/plural.
- [x] 5.2 Implement D4.

## 6. Release (0.25–0.5 d)

- [x] 6.1 Mandatory security review: no path to `/purge`; only trashed ids are sent; sync-before-confirm in place; nothing but HTTP status in logs.
  Done; see Results.
- [x] 6.2 CHANGELOG "Added": Empty Trash in the Trash view.
- [x] 6.3 The change removes the requirement "User can empty trash" from `vault-item-delete` (REMOVED, with reason and migration), so archiving replaces it with this change's `empty-trash` requirements. No warning line in the living spec is needed (decided 2026-10-26: archive in the same PR).
- [x] 6.4 `openspec validate fix-empty-trash --type change --strict`.

## Results (2026-10-25)

- `EmptyTrashRequestTests` (bulk request, purge source scan), `EmptyTrashRepositoryTests` (only
  trashed ids, chunks 500/500/200, failing chunk), `EmptyTrashUseCaseTests` (sync before and after,
  remaining), `EmptyTrashViewModelTests` (confirmation text, refresh failure, singular/plural,
  cancel). `StubURLProtocol` fails any test that requests a path ending in `/purge`.
- Design D3 placement: the button sits in the content column's toolbar, where "+" is in other
  categories ("+" is not shown in Trash since `fix-ui-journey-findings`).
- "remaining" counts the requested items still in Trash after the follow-up sync; items trashed
  meanwhile on another device do not count as failures.
- If the follow-up sync fails, the result comes from the cache, which already reflects every chunk
  that succeeded.
- 4.3: XCUITests added (`TrashJourneyTests.testEmptyTrash_refreshFails_deletesNothing`,
  `testEmptyTrash_notOfferedOutsideTrash`); both pass (2026-10-26). Without a server, the test vault
  takes the refresh-failure path, so the full journey (delete, empty state) still needs a test server.
- 6.1 security review: no path to `/purge`, only trashed ids, sync before confirm. Fixed after
  review (design D6): state reset on lock, alert passes its confirmation, chunks continue after a
  failure, failure cause and sync status in the result, logs with HTTP status only, and the sync
  no longer writes after a lock. Not tested: the button's disabled state with an empty Trash.
- **Verified on the Mac (2026-10-26):** all 642 unit tests pass on this branch; the full UI suite passes on the top of the series (`fix/017`). The test run found two test bugs, fixed here: `SyncRepositoryImplTests` never unlocked
  the mock, and one `EmptyTrashTests` case set the sync error too late.
- Open: 1.1 (rig); 4.3's full journey (needs a test server).

