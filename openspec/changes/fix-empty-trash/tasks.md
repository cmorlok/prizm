# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies. Task 2.1 (purge guard) comes first and can merge on its own.

## 1. Confirm server behaviour (0.25 d)

- [ ] 1.1 On the rig (Vaultwarden 1.37.4) and Bitwarden self-hosted if available: `DELETE /api/ciphers` with `{"ids": [...]}` for two trashed personal items and one org item the user may not delete. Record in design.md, Context, the status code and which items remain. Never call `/ciphers/purge`, not even on the rig.

## 2. API call and purge guard (0.5 d)

- [ ] 2.1 Failing guard test (design D5): the recording mock URL protocol fails any test whose request path ends in `/purge`; a source scan fails if `ciphers/purge` appears in `Prizm/` outside a warning comment. Fix the comment at `PrizmAPIClient.swift:1089`.
- [ ] 2.2 Failing test: `permanentDeleteCiphers(ids:)` sends `DELETE /api/ciphers` with JSON body `{"ids": [...]}` and the bearer token.
- [ ] 2.3 Implement it in `PrizmAPIClient`, with a §VII comment that names the purge endpoint and why it must not be used, with source references.

## 3. Repository and use case (0.5 d)

- [ ] 3.1 Failing test (mock API): `emptyTrash()` sends only the ids of items with `isDeleted == true`, in chunks of 500; active items are never in a request.
- [ ] 3.2 Failing test: after the delete calls (success or error), a sync runs and `EmptyTrashResult.remaining` is the trash count after that sync.
- [ ] 3.3 Implement `VaultRepository.emptyTrash()`, `EmptyTrashUseCase` (Domain) and its Data impl; wire in `AppContainer`.

## 4. Trash UI (0.5 d)

- [ ] 4.1 Failing view-model test: Empty Trash first syncs, then exposes the confirmation with the fresh count; a failed sync shows the D2 message and sends no delete.
- [ ] 4.2 Add the toolbar button and confirmation (design D3) to `TrashView`, using the destructive style. Add `AccessibilityID.Trash.emptyTrashButton`.
- [ ] 4.3 VoiceOver: button label "Empty Trash"; result announcement (§VIII). XCUITest: trash with two items → Empty Trash → confirm → empty state shown.

## 5. Partial failure (0.25 d)

- [ ] 5.1 Failing view-model test: `remaining > 0` shows the D4 message with the right count and singular/plural.
- [ ] 5.2 Implement D4.

## 6. Release (0.25–0.5 d)

- [ ] 6.1 Mandatory security review: no path to `/purge`; only trashed ids are sent; sync-before-confirm in place; nothing but HTTP status in logs.
- [ ] 6.2 CHANGELOG "Added": Empty Trash in the Trash view.
- [ ] 6.3 At archive time, replace the requirement "User can empty trash" in `openspec/specs/vault-item-delete/spec.md:53-70` with this change's `empty-trash` requirements, removing every mention of `DELETE /ciphers/purge`. Until then, add a one-line warning under that requirement pointing to this change (needs the maintainer's agreement, since it edits a living spec before archive).
- [ ] 6.4 `openspec validate fix-empty-trash --type change --strict`.
