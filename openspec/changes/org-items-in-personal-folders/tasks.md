# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-favorite-and-folder-partial-updates` (moving an org item to a folder, or
deleting its folder, keeps its organization and collections).

## 1. Verify (0.25 d)

- [ ] 1.1 On Vaultwarden 1.37.4, with two members of one org, check that:
  - member A files an org item into A's folder in the browser extension
  - A's sync shows that `folderId`
  - B's sync shows B's own value (or null)

  Record the result in design.md. Mark the official server "source-reviewed, not tested".

## 2. Folder index (0.25 d)

- [x] 2.1 Failing test: an org item with `folderId == "f1"` appears in `.folder("f1")`, and the folder count includes it.
- [x] 2.2 Remove the org check (design D1). Existing personal-folder tests stay green.

## 3. Regression guard (included in 2)

- [x] 3.1 Test: delete a folder that contains an org item, and drag an org item into a folder. In both cases the item keeps `organizationId` and `collectionIds` and stays listed in its collections (design D3; implemented by the prerequisite).

## 4. Presentation (0.5 d)

- [x] 4.1 `ItemEditView`: folder picker for org items below the collection picker (design D2). View model test: saving an org item with a new folder sends `folderId` and keeps `organizationId` and `collectionIds`.
- [ ] 4.2 Drag and drop of an org item onto a folder. View model test, plus an XCUITest journey: drag an org item to a folder; it appears there and still shows its organization badge.
- [x] 4.3 VoiceOver: the folder picker label is "Folder" for both item kinds (§VIII).

## 5. Specs and release (0.25 d)

- [x] 5.1 CHANGELOG "Fixed": organization items filed in your folders in other Bitwarden apps now show in those folders, and you can file organization items into folders in Prizm.
- [ ] 5.2 Before archiving: repair the structure of `openspec/specs/org-vault-items/spec.md` (add `## Purpose` and `## Requirements`) in a separate commit with no requirement changes. Then replace the folder rule at line 19 and the scenario at lines 31-34 with the requirement from this change.
- [x] 5.3 `openspec validate org-items-in-personal-folders --type change --strict`.

## Results (2026-10-26)

- Source check: Vaultwarden 1.37.4's `Cipher::to_json` sends the requesting user's folder for every
  cipher (`cipher_sync_data.cipher_folders`); `CipherMapper` already maps and sends `folderId` for
  org items.
- `OrgItemsInFoldersTests`: an org item is listed and counted in its folder; moving it to another
  folder or deleting its folder keeps its organization and collections (the prerequisite's fix);
  the edit sheet saves a folder for an org item and keeps both.
- 4.2: drag and drop had no org restriction; the folder index filter was the only thing in the way.
  No XCUITest: the UI test fixture has no organization item yet (open).
- 4.3: the folder picker has the label "Folder" (it had none, for personal items too).
- Review (2026-10-26): Prizm does not model the cipher `edit` permission, so the edit sheet also
  opens for read-only org items, and a full `PUT /ciphers/{id}` is refused for them. Fixed: when
  only folder and/or favorite changed, `VaultRepositoryImpl.update` saves through `/partial`
  (read access is enough on Vaultwarden 1.37.4 `put_cipher_partial` and Bitwarden `PutPartial`),
  like the official clients' "partial-edit" mode. Any other change still sends the full PUT, which
  fails for read-only items as before (modelling `edit` is out of scope). The collection picker
  got the label "Collection".
- **Not verified on the Mac yet** (test runner hung): unit tests.
- Open: 1.1 (rig, two members), 4.2 XCUITest, 5.2 at archive time.

