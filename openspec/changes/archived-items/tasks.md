# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-cipher-edit-data-loss` (merged) preserves `archivedDate` on `PUT`.

## 1. Verify server behaviour (0.5 d)

- [ ] 1.1 Against Vaultwarden 1.37.4 (and, from source, the official server), record in design.md:
  - the response of `PUT /ciphers/{id}/archive` and `/unarchive`
  - the `archivedDate` format in sync
  - whether `PUT /ciphers/{id}` without `archivedDate` unarchives on the official server
  - the 404 body on a server without archive, and the 404 body for an unknown id on a server with it
  - the official answer model of `PutArchive`/`PutUnarchive` and any `[RequireFeature]` on the controller (from source)
  - whether soft delete or restore clears `archivedDate` (Vaultwarden 1.37.4 and the official server)
- [ ] 1.2 Capture a scrubbed sync fixture with one archived item, one archived and deleted item, and one normal item.

## 2. Decode and model (0.5 d)

- [ ] 2.1 Failing test: decoding the fixture gives `VaultItem.archivedDate` set for the two archived items and `nil` for the other.
- [ ] 2.2 Read `RawCipher.archivedDate` (kept by `fix-cipher-edit-data-loss`) into `VaultItem.archivedDate`, with `isArchived` / `isActive`; unparseable value counts as archived and is logged (design D1). Every builder carries it (design D2). Test: editing or moving an archived item keeps it in Archive in the cache.

## 3. Lists (0.5–1 d)

- [ ] 3.1 Failing tests for `buildIndexes`:
  - archived items are absent from All Items, Favorites, every type, folder, collection, organization and Codes
  - `.archive` lists archived non-deleted items
  - `.trash` lists both deleted items
  - counts match
- [ ] 3.2 Implement design D2. `SidebarSelection.archive` in `displayName`, `==` and `hash` (value 10). Tests: `.archive == .archive`, its hash differs from `.trash`; search inside `.archive` finds archived items, search elsewhere and global search don't.
- [ ] 3.3 Sidebar "Archive" entry with count in the `.trash` section, shown when the count is above 0 (design D5, D6); selection falls back to All Items when it disappears while selected. VoiceOver label. DesignSystem tokens. View model tests.
- [ ] 3.4 Move the `allItems()` lookups by id to `itemDetail(id:)` (`AttachmentRepositoryImpl` ×2, `VaultBrowserViewModel` refresh); the conversion notice reads `allItems()` + Archive. Tests: an upload or delete on an archived item keeps its other attachments; the detail of an archived item refreshes after a sync.

## 4. Archive and Unarchive (1 d)

- [ ] 4.1 `PrizmAPIClient.archiveCipher(id:)` / `unarchiveCipher(id:)`. Mock-API tests: method, path, no body, answer decoded (full and mini cipher shapes).
- [ ] 4.2 `VaultRepository.setArchived(id:archived:)` (design D3: serialised, token-checked, the answer not applied, the record fetched after the request) and `SetItemArchivedUseCase` calling it. `archivedDate` in `RecordContent.ignoredMembers`; the refresh after delete/restore/favourite/move/collections copies `archivedDate`. Tests: the item moves between All Items and Archive; a lock during the request changes nothing; a later edit sends the new `archivedDate` and does not conflict; an archive change found by a refresh reaches the lists.
- [ ] 4.3 UI: context menu and toolbar actions, always offered (design D4); a server refusal shows the server's message and leaves the item in place. View model tests.
- [ ] 4.4 `LegacyArchiveSupport` (design D5) with the marker `// LEGACY(Vaultwarden < 1.36.0, Bitwarden server < v2025.10.0): remove when those versions are no longer supported`: 404 without a server message → "This server doesn't support archiving items."; 404 with a message → that message; `isArchiveSupported()` from the stored records (empty vault counts as supported), so sync, create and update answers re-check it; hide the Archive action while false. Tests: a Vaultwarden 1.35.4-style sync fixture (no `archivedDate` anywhere) gives the same lists as today and no Archive action; with the key present, `LegacyArchiveSupport` changes nothing. Add it to the "Legacy adapters" table in `FIX-ORDER.md` if missing.
- [ ] 4.5 "Archived" badge in the detail header; VoiceOver announcement after each action (§VIII).

## 5. Release (0.5 d)

- [ ] 5.1 XCUITest journey on the seeded UI-test vault (`--ui-test-archived` adds one archived login; every seeded record carries `archivedDate`): the item is absent from All Items, listed in Archive with its badge, and the Archive/Unarchive actions are present. The action itself needs server writes (`UITestPrerequisite.serverWrites`, skip with reason); it is covered by the rig check 5.2.
- [ ] 5.2 Rig check (Vaultwarden 1.37.4): archive and unarchive in Prizm; the official `bw` CLI shows the archive state; an item archived with the API shows in Prizm's Archive only; editing an archived item in Prizm keeps it archived; delete and restore of an archived item.
- [ ] 5.3 Add to `macos-autofill-credential-provider` design: archived items are excluded from matching and from the identity store.
- [ ] 5.4 CHANGELOG "Added": Archive view, and archive and unarchive actions (no premium needed). "Fixed": items archived in other Bitwarden apps no longer show in the normal lists.
- [ ] 5.5 `openspec validate archived-items --type change --strict`.
