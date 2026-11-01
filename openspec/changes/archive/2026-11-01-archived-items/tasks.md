# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-cipher-edit-data-loss` (merged) preserves `archivedDate` on `PUT`.

## 1. Verify server behaviour (0.5 d)

- [x] 1.1 Against Vaultwarden 1.37.4 (and, from source, the official server), record in design.md:
  - the response of `PUT /ciphers/{id}/archive` and `/unarchive`
  - the `archivedDate` format in sync
  - whether `PUT /ciphers/{id}` without `archivedDate` unarchives on the official server
  - the 404 body on a server without archive, and the 404 body for an unknown id on a server with it
  - the official answer model of `PutArchive`/`PutUnarchive` and any `[RequireFeature]` on the controller (from source)
  - whether soft delete or restore clears `archivedDate` (Vaultwarden 1.37.4 and the official server)

  Done, recorded in design.md, Context (rig probes 2026-10-31, run mvwquy51, `.planning/batch3/rig038.mjs`; official server source v2026.10.1): both endpoints answer the full cipher (`cipherDetails`; official `CipherResponseModel`, no feature attribute); `archivedDate` is an ISO 8601 string with microseconds, `null` (key present) when not archived; a `PUT` without `archivedDate` unarchives on both servers (official `UpdateUserSpecificJsonField` removes the user's entry for `null`); an unknown id answers **400** with a message on both servers ("Cipher doesn't exist", official "Cipher was not archived…"), so only a server without the route answers 404 (Vaultwarden 1.35.4 is not on the rig: unit tests stand in); soft delete and restore keep `archivedDate` on both.
- [x] 1.2 Capture a scrubbed sync fixture with one archived item, one archived and deleted item, and one normal item. Done as: the captured, scrubbed `sync-golden-1.37.4.json` holds one archived and five normal items; the archived-and-deleted and deleted shapes are built server-shaped in `ArchivedItemsTests` (`record(_:archivedDate:)`), and the rig probe of 1.1 confirmed the sync shape they follow.

## 2. Decode and model (0.5 d)

- [x] 2.1 Failing test: decoding the fixture gives `VaultItem.archivedDate` set for the two archived items and `nil` for the other. Done: `testMap_archivedDate`, `testIndexes_archivedItemsLeaveEveryEverydayList`. Tests were written with the code (no separate red run).
- [x] 2.2 Read `RawCipher.archivedDate` (kept by `fix-cipher-edit-data-loss`) into `VaultItem.archivedDate`, with `isArchived` / `isActive`; unparseable value counts as archived and is logged (design D1). Every builder carries it (design D2). Test: editing or moving an archived item keeps it in Archive in the cache. Done: `testMap_unreadableArchivedDate_countsAsArchived`, `testBuilders_keepTheArchiveState`, `testArchive_thenEdit_sendsTheNewStateAndNoConflict`; green 20261030T202324Z (1379).

## 3. Lists (0.5–1 d)

- [x] 3.1 Failing tests for `buildIndexes`:
  - archived items are absent from All Items, Favorites, every type, folder, collection, organization and Codes
  - `.archive` lists archived non-deleted items
  - `.trash` lists both deleted items
  - counts match

  Done: `testIndexes_archivedItemsLeaveEveryEverydayList` (written with the code).
- [x] 3.2 Implement design D2. `SidebarSelection.archive` in `displayName`, `==` and `hash` (value 10). Tests: `.archive == .archive`, its hash differs from `.trash`; search inside `.archive` finds archived items, search elsewhere and global search don't. Done: `testSelection_archiveEqualsItselfAndHashesApart`, `testSearch_findsArchivedItemsOnlyInsideArchive`.
- [x] 3.3 Sidebar "Archive" entry with count in the `.trash` section, shown when the count is above 0 (design D5, D6); selection falls back to All Items when it disappears while selected. VoiceOver label. DesignSystem tokens. View model tests. Done: UI commit (green 20261030T202626Z, 1383), `VaultBrowserViewModelArchiveTests`; code review R2: unarchiving the last archived item keeps the item selected on the fallback (red 20261031T080448Z, green 20261031T080645Z).
- [x] 3.4 Move the `allItems()` lookups by id to `itemDetail(id:)` (`AttachmentRepositoryImpl` ×2, `VaultBrowserViewModel` refresh); the conversion notice reads `allItems()` + Archive. Tests: an upload or delete on an archived item keeps its other attachments; the detail of an archived item refreshes after a sync. Done: `testItemDetail_findsArchivedItems`; the attachment tests `test_upload_toAnArchivedItem_keepsItsOtherAttachments` and `test_delete_onAnArchivedItem_keepsItsOtherAttachments` were added at verification (verify W2, 2026-10-31).

## 4. Archive and Unarchive (1 d)

- [x] 4.1 `PrizmAPIClient.archiveCipher(id:)` / `unarchiveCipher(id:)`. Mock-API tests: method, path, no body, answer decoded (full and mini cipher shapes). Done: `testArchiveAndUnarchive_putToTheirPathsWithoutABody`, `testAnswer_keepsNullApartFromAbsent` (code review R5).
- [x] 4.2 `VaultRepository.setArchived(id:archived:)` (design D3: serialised, token-checked, the answer not applied, the record fetched after the request) and `SetItemArchivedUseCase` calling it. `archivedDate` in `RecordContent.ignoredMembers`; the refresh after delete/restore/favourite/move/collections copies `archivedDate`. Tests: the item moves between All Items and Archive; a lock during the request changes nothing; a later edit sends the new `archivedDate` and does not conflict; an archive change found by a refresh reaches the lists. Done: `testArchive_sendsTheRequestAndMovesTheItem`, `testUnarchive_movesTheItemBack`, `testArchive_lockDuringTheRequest_changesNothing`, `testArchive_thenEdit_…`, `testArchive_afterAnotherClientsEdit_keepsTheConflictCheck` (code review R1: answer no longer applied), `testRestoreFromTrash_keepsTheItemArchived`, `testRefreshAfterAFavorite_bringsAnArchiveChangeMadeElsewhere`, `testRefreshFindingAnotherEdit_stillAppliesTheArchiveState` (verify W1/S3; red 20261031T182458Z, green 20261031T182515Z). Serialisation of two requests has no own test (code review note).
- [x] 4.3 UI: context menu and toolbar actions, always offered (design D4); a server refusal shows the server's message and leaves the item in place. View model tests. Done: `VaultBrowserViewModelArchiveTests` (refusal, announcement, session check after a lock: code review R4); `canSetArchived` also asserted for a read-only org item (verify S4).
- [x] 4.4 `LegacyArchiveSupport` (design D5) with the marker `// LEGACY(Vaultwarden < 1.36.0, Bitwarden server < v2025.10.0): remove when those versions are no longer supported`: 404 without a server message → "This server doesn't support archiving items."; 404 with a message → that message; `isArchiveSupported()` from the stored records (empty vault counts as supported), so sync, create and update answers re-check it; hide the Archive action while false. Tests: a Vaultwarden 1.35.4-style sync fixture (no `archivedDate` anywhere) gives the same lists as today and no Archive action; with the key present, `LegacyArchiveSupport` changes nothing. Add it to the "Legacy adapters" table in `FIX-ORDER.md` if missing. Done: `Data/Repositories/Legacy/LegacyArchiveSupport.swift`, `testArchive_404WithoutMessage_isUnsupported_withMessage_isTheServers`, `testSupport_detectedFromTheStoredRecords`, `testLegacyServer_listsAreUnchanged`; FIX-ORDER.md already lists it (change-request branch).
- [x] 4.5 "Archived" badge in the detail header; VoiceOver announcement after each action (§VIII). Done; VoiceOver hand check (Christian, 2026-10-31): badge read, "Item archived"/"Item unarchived" announced, unarchive keeps the selection.

## 5. Release (0.5 d)

- [x] 5.1 XCUITest journey on the seeded UI-test vault (`--ui-test-archived` adds one archived login; every seeded record carries `archivedDate`): the item is absent from All Items, listed in Archive with its badge, and the Archive/Unarchive actions are present. The action itself needs server writes (`UITestPrerequisite.serverWrites`, skip with reason); it is covered by the rig check 5.2. Done: `ArchivedItemsJourneyTests` 2/2 (20261031T172954Z, after adding the missing pbxproj entries: `Prizm/UITests` is not a synchronized folder) and in the final batch UI run.
- [x] 5.2 Rig check (Vaultwarden 1.37.4): archive and unarchive in Prizm; the official `bw` CLI shows the archive state; an item archived with the API shows in Prizm's Archive only; editing an archived item in Prizm keeps it archived; delete and restore of an archived item. Done: `.planning/batch3/live038.sh` on fix/038, 2026-10-31 (unit run 20261031T183859Z): all PASS, read back with the API and `bw` 2026.9.1 (the item archived by Prizm and the edited one archived, the unarchived one not, Prizm's edit is the name `bw` reads; after delete and restore Prizm and the server both keep the item archived). The earlier batch run 20261031T081759Z covered archive only.
- [x] 5.3 Add to `macos-autofill-credential-provider` design: archived items are excluded from matching and from the identity store. Done on the change-request branch (8d8360f3).
- [x] 5.4 CHANGELOG "Added": Archive view, and archive and unarchive actions (no premium needed). "Fixed": items archived in other Bitwarden apps no longer show in the normal lists. Done.
- [x] 5.5 `openspec validate archived-items --type change --strict`. Done before the archive.
