# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies. If `fix-cipher-edit-data-loss` has landed, its stale-write tests must keep passing
when a `collections_v2` call follows the PUT.

## 1. Confirm server behaviour (0.25–0.5 d)

- [ ] 1.1 On Vaultwarden 1.37.4 (rig) and Bitwarden self-hosted if available, with a member who has one writable and one read-only collection: record in design.md the `collections_v2` response when (a) the read-only collection is posted back, (b) it is left out, (c) the list is unchanged. Answers Open Question 1.
- [ ] 1.2 Regression test for today's bug: an item in "A" and "B" keeps "B" when the user checks or unchecks another collection (in the 3.1 view-model tests). Today's single-choice logic lives in the view's `Picker` binding, which has no unit seam, so no test pins the old behaviour; the XCUITest in 3.3 covers it end to end.

## 2. Collection permissions and the final-list helper (0.5 d)

- [ ] 2.1 Failing test: `RawCollection` decodes `readOnly`, `hidePasswords`, `manage` (both casings; missing → false). `OrgCollection.readOnly` is mapped in `SyncRepositoryImpl`.
- [ ] 2.2 Failing table-driven tests for `CollectionAssignment.finalIds` (design D2): read-only kept, unknown ids kept, other-org ids kept, writable add and remove, stable order, empty result.
- [ ] 2.3 Implement D1 and D2 (Domain helper, Foundation only).

## 3. Multi-select picker (1–1.5 d)

- [ ] 3.1 Failing view-model test: the edit view model exposes writable collections (sorted), read-only assignments, and the checked state; toggling updates `draft.collectionIds` through D2 only.
- [ ] 3.2 Replace the `Picker` in `ItemEditView.swift:56-97` with the D3 checkbox list. DesignSystem tokens only; no raw sizes.
- [ ] 3.3 VoiceOver: each checkbox labelled with the collection name; read-only rows have the D3 hint (§VIII). XCUITest: open an org item, check a second collection, save, reopen, both checked.
- [ ] 3.4 Empty state when no collection is writable (D3). The rows scroll inside the card past a DesignSystem max height; create mode pre-fills only a writable collection.

## 4. Required collection (0.25 d)

- [ ] 4.1 Failing test: `canSave` is false for an org draft whose final list is empty, on create and on edit; the hint text is exposed.
- [ ] 4.2 Remove "None"; implement D4.

## 5. Collections call only on change (1–1.25 d)

- [ ] 5.1 Failing test (mock API): an org edit without collection change sends only `PUT /api/ciphers/{id}`.
- [ ] 5.2 Failing test: a collection change sends `PUT /api/ciphers/{id}/collections_v2` with the D2 list after the cipher PUT; the response cipher patches `collectionIds` and `revisionDate`.
- [ ] 5.3 Failing tests: `unavailable: true` removes the item locally and throws `VaultError.savedButAccessLost`; a `collections_v2` error leaves the item with the PUT fields and the original collections and throws `VaultError.collectionChangeNotSaved`.
- [ ] 5.4 Implement D5 in `PrizmAPIClient` and `VaultRepositoryImpl.update`; the original set is the stored record's.
- [ ] 5.5 Failing tests for the legacy adapter (design D5a): `collections_v2` answers 404 with an empty body → `LegacyCipherCollectionsEndpoint` sends `PUT /api/ciphers/{id}/collections` with the same list and its cipher patches the local item; 405 → same; 404 with an error body → no fallback, D5 error path; `collections_v2` answers 200 → the legacy endpoint is never called.
- [ ] 5.6 Implement `LegacyCipherCollectionsEndpoint` in its own file in `Data/Network`, with the `// LEGACY(Bitwarden server < v2024.6.0): remove when those versions are no longer supported` marker.
- [ ] 5.7 `ItemEditViewModel` maps `collectionChangeNotSaved` and the "no longer have access" outcome to the D5 messages, announced to VoiceOver; the sheet stays open on error.
- [ ] 5.8 Rewrite the comment at `PrizmAPIClient.swift:95-98` (D6, §VII).
- [ ] 5.9 D2a (review 2026-10-30): `CollectionAssignment.rebased` and `DraftVaultItem.originalCollectionIds`; the request leaves out only known read-only ids, unknown ids are sent back. Tests: `CollectionAssignmentTests.testRebased`, `CollectionChangeOnlyTests` (added elsewhere: plain edit, plus one added here; unknown id sent back; last writable unchecked sends `[]`).

## 6. Release (0.5 d)

- [ ] 6.1 Live check on the rig with two members: item in two collections stays in both after an edit in Prizm; adding a third works; a read-only assignment survives; no `Cipher_UpdatedCollections` event for a plain edit (Vaultwarden event log, if enabled).
- [ ] 6.2 Mandatory security review: no write to a read-only collection, no removal of assignments the user did not uncheck, error paths leave the cache truthful.
- [ ] 6.3 CHANGELOG "Fixed": saving an organization item no longer removes it from its other collections; read-only collections are no longer offered; an organization item can no longer be created without a collection. "Changed": the collection picker is now a multi-select.
- [ ] 6.4 At archive time, replace the requirement in `openspec/specs/vault-item-create/spec.md:31-46` with this change's requirements.
- [ ] 6.5 `openspec validate fix-collection-assignment --type change --strict`.
