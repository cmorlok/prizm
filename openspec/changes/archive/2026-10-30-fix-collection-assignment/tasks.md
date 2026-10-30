# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies. If `fix-cipher-edit-data-loss` has landed, its stale-write tests must keep passing
when a `collections_v2` call follows the PUT.

Runs: red `20261030T085111Z` (compile: `CollectionAssignment`, `RawCollection.readOnly` missing),
green `20261030T085904Z` (1118 unit tests). Rig fix (read-only ids left out of the request): red
`20261030T111725Z` (2 failures in `CollectionChangeOnlyTests`), green `20261030T111754Z` (1120).
Review fix (D2a, unknown ids sent back): red `20261030T130841Z` (compile: `rebased` missing), green
`20261030T130928Z` (1124). Squashed code commit 7372ffba: `20261030T133849Z`, 1124 passed, 0 failed.

## 1. Confirm server behaviour (0.25–0.5 d)

- [x] 1.1 On Vaultwarden 1.37.4 (rig) and Bitwarden self-hosted if available, with a member who has one writable and one read-only collection: record in design.md the `collections_v2` response when (a) the read-only collection is posted back, (b) it is left out, (c) the list is unchanged. Answers Open Question 1. Done: rig run `20261030T113852Z` (checks `025.1.1a`–`c`): (a) 400 "No rights to modify the collection", (b) 200 with the cipher, read-only R kept, (c) 400. Recorded in design.md Context; Open Question 1 answered. Bitwarden self-hosted was not available (no rig).
- [x] 1.2 Regression test for today's bug: an item in "A" and "B" keeps "B" when the user checks or unchecks another collection (in the 3.1 view-model tests). Today's single-choice logic lives in the view's `Picker` binding, which has no unit seam, so no test pins the old behaviour; the XCUITest in 3.3 covers it end to end. Done: `CollectionPickerViewModelTests.testCheckingAnother_keepsTheExistingOnes`, `testUnchecking_removesOnlyThatOne_andKeepsReadOnlyAndUnknown`.

## 2. Collection permissions and the final-list helper (0.5 d)

- [x] 2.1 Failing test: `RawCollection` decodes `readOnly`, `hidePasswords`, `manage` (both casings; missing → false). `OrgCollection.readOnly` is mapped in `SyncRepositoryImpl`. Done: `CipherCollectionsEndpointTests.testRawCollection_decodesPermissions_bothCasings_missingIsFalse` (red `20261030T085111Z`); mapping in `SyncRepositoryImpl.swift:231-232` (no separate sync test).
- [x] 2.2 Failing table-driven tests for `CollectionAssignment.finalIds` (design D2): read-only kept, unknown ids kept, other-org ids kept, writable add and remove, stable order, empty result. Done: `CollectionAssignmentTests.testFinalIds` (9 cases, also duplicates and a non-writable selection).
- [x] 2.3 Implement D1 and D2 (Domain helper, Foundation only). Done: `Domain/Utilities/CollectionAssignment.swift`, `OrgCollection.readOnly`, `RawCollection` flags.

## 3. Multi-select picker (1–1.5 d)

- [x] 3.1 Failing view-model test: the edit view model exposes writable collections (sorted), read-only assignments, and the checked state; toggling updates `draft.collectionIds` through D2 only. Done: `CollectionPickerViewModelTests` (12 tests).
- [x] 3.2 Replace the `Picker` in `ItemEditView.swift:56-97` with the D3 checkbox list. DesignSystem tokens only; no raw sizes. Done: `ItemEditView.collectionsCard` / `collectionRows` (`Spacing.rowVertical`, `rowHorizontal`, `pageMargin`, `cardBottom`, `collectionListMaxHeight`; `Typography.fieldValue`, `fieldLabel`, `utility`).
- [x] 3.3 VoiceOver: each checkbox labelled with the collection name; read-only rows have the D3 hint (§VIII). XCUITest: open an org item, check a second collection, save, reopen, both checked. Done: VoiceOver checked by hand by Christian on 2026-10-30: the collection checkboxes read correctly. `CollectionPickerJourneyTests`: rerun `20261030T102259Z` passed (`testUncheckingTheWritableOne_…` passed; `testCheckboxes_…` passed its checks and then skipped at `UITestPrerequisite.serverWrites()`). UI-test mode has no server, so save and reopen are covered by the live rig instead: `prizm 025.6.1.add` and `025.6.1.add.server` (W3 added, item in R, W1, W3 afterwards).
- [x] 3.4 Empty state when no collection is writable (D3). The rows scroll inside the card past a DesignSystem max height; create mode pre-fills only a writable collection. Done: `ItemEditViewModel.noWritableCollectionNote`, `Spacing.collectionListMaxHeight` (170 pt) with `ViewThatFits`; `testCreate_prefillsOnlyAWritableCollection`.

## 4. Required collection (0.25 d)

- [x] 4.1 Failing test: `canSave` is false for an org draft whose final list is empty, on create and on edit; the hint text is exposed. Done: `testUncheckingTheLastOne_disablesSave_andShowsTheHint`, `testCreate_withoutCollection_cannotBeSaved`, `testItemOnlyInAReadOnlyCollection_canStillBeSaved`.
- [x] 4.2 Remove "None"; implement D4. Done: `collectionHint`, `canSave`; the checkbox list has no "None".

## 5. Collections call only on change (1–1.25 d)

- [x] 5.1 Failing test (mock API): an org edit without collection change sends only `PUT /api/ciphers/{id}`. Done: `CollectionChangeOnlyTests.testEditWithoutCollectionChange_sendsOnlyThePut`, `testSameCollectionsInAnotherOrder_isNoChange`.
- [x] 5.2 Failing test: a collection change sends `PUT /api/ciphers/{id}/collections_v2` with the D2 list after the cipher PUT; the response cipher patches `collectionIds` and `revisionDate`. Done: `testCollectionChange_sendsTheListAfterThePut_andTakesTheAnswer`; route and body in `CipherCollectionsEndpointTests.testCollectionsV2_sendsTheListAndReadsTheCipher`.
- [x] 5.3 Failing tests: `unavailable: true` removes the item locally and throws `VaultError.savedButAccessLost`; a `collections_v2` error leaves the item with the PUT fields and the original collections and throws `VaultError.collectionChangeNotSaved`. Done: `testUnavailable_removesTheItemLocally_andReportsIt`, `testCollectionsFailure_keepsTheOriginalCollectionsLocally`.
- [x] 5.4 Implement D5 in `PrizmAPIClient` and `VaultRepositoryImpl.update`; the original set is the stored record's. Done: `PrizmAPIClient.updateCipherCollections` (`collections_v2`, `CipherCollectionsResult`), `VaultRepositoryImpl.update` (`collectionsChanged` against the stored record, `requestCollectionIds`).
- [x] 5.5 Failing tests for the legacy adapter (design D5a): `collections_v2` answers 404 with an empty body → `LegacyCipherCollectionsEndpoint` sends `PUT /api/ciphers/{id}/collections` with the same list and its cipher patches the local item; 405 → same; 404 with an error body → no fallback, D5 error path; `collections_v2` answers 200 → the legacy endpoint is never called. Done: `CipherCollectionsEndpointTests` (`testLegacyFallback_on404WithEmptyBody`, `_on405`, `testNoFallback_on404WithErrorBody`, `testNoFallback_onOtherErrors`, `testCollectionsV2_…`).
- [x] 5.6 Implement `LegacyCipherCollectionsEndpoint` in its own file in `Data/Network`, with the `// LEGACY(Bitwarden server < v2024.6.0): remove when those versions are no longer supported` marker. Done: `Data/Network/Legacy/LegacyCipherCollectionsEndpoint.swift`.
- [x] 5.7 `ItemEditViewModel` maps `collectionChangeNotSaved` and the "no longer have access" outcome to the D5 messages, announced to VoiceOver; the sheet stays open on error. Done: `ConflictState.accessLost` (banner, Close, Save disabled; `testSavedButAccessLost_showsTheMessage_blocksSave_andOffersClose`); `collectionChangeNotSaved` kept from `fix-cipher-edit-data-loss` (`ItemEditViewModelConflictTests`); the banner is announced through `ItemEditView`'s `onChange(of: bannerMessage)`.
- [x] 5.8 Rewrite the comment at `PrizmAPIClient.swift:95-98` (D6, §VII). Done: `PrizmAPIClient.swift:94-109` (writable assignments only, read-only ids refused by Vaultwarden, empty list unassigns, links to the SQL procedure and the rig result).
- [x] 5.9 D2a (review 2026-10-30): `CollectionAssignment.rebased` and `DraftVaultItem.originalCollectionIds`; the request leaves out only known read-only ids, unknown ids are sent back. Tests: `CollectionAssignmentTests.testRebased`, `CollectionChangeOnlyTests` (added elsewhere: plain edit, plus one added here; unknown id sent back; last writable unchecked sends `[]`). Done: red `20261030T130841Z`, green `20261030T130928Z` (1124).

## 6. Release (0.5 d)

- [x] 6.1 Live check on the rig with two members: item in two collections stays in both after an edit in Prizm; adding a third works; a read-only assignment survives; no `Cipher_UpdatedCollections` event for a plain edit (Vaultwarden event log, if enabled). Done: rig run `20261030T113852Z` on Vaultwarden 1.37.4, member B: `025.6.1.plain.server` (item stays in R, W1, W2), `025.6.1.add.server` (R, W1, W3), `025.6.1.events` (plain edit: no 1106 event; W3 add: 1106). The run used the code before D2a; for these two cases D2a sends the same request (checked against `CollectionAssignment.rebased`), and D2a itself is covered by unit tests.
- [x] 6.2 Mandatory security review: no write to a read-only collection, no removal of assignments the user did not uncheck, error paths leave the cache truthful. Done: independent review 2026-10-30; findings fixed or recorded as risks; security note in design.md "Review".
- [x] 6.3 CHANGELOG "Fixed": saving an organization item no longer removes it from its other collections; read-only collections are no longer offered; an organization item can no longer be created without a collection. "Changed": the collection picker is now a multi-select. Done: entries under "Unreleased" ("Fix: saving an organization item no longer removed it from collections you did not uncheck …", "Fix: the collection picker no longer offered collections you can only view …", "Fix: an organization item can no longer be saved without a collection …", "Changed: an organization item's collections are now a list of checkboxes …").
- [x] 6.4 At archive time, replace the requirement in `openspec/specs/vault-item-create/spec.md` (lines 35-55) with this change's requirements. Done by hand in the archive commit (OpenSpec refuses a MODIFIED block that drops scenarios); the old claim that the sheet shows the organization name is left out (it never did).
- [x] 6.5 `openspec validate fix-collection-assignment --type change --strict` and `/opsx:verify`. Valid; `/opsx:verify` 2026-10-30: no critical issues; the stale design and spec sentences it found are corrected in the archive commit.
- [x] 6.6 Archive the change.
