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

- [ ] 2.1 Failing test: an org item with `folderId == "f1"` appears in `.folder("f1")`, and the folder count includes it.
- [ ] 2.2 Remove the org check (design D1). Existing personal-folder tests stay green.

## 3. Regression guard (included in 2)

- [ ] 3.1 Test: delete a folder that contains an org item, and drag an org item into a folder. In both cases the item keeps `organizationId` and `collectionIds` and stays listed in its collections (design D3; implemented by the prerequisite).

## 4. Presentation (0.5 d)

- [ ] 4.1 `ItemEditView`: folder picker for org items below the collection picker (design D2). View model test: saving an org item with a new folder sends `folderId` and keeps `organizationId` and `collectionIds`.
- [ ] 4.2 Drag and drop of an org item onto a folder. View model test, plus an XCUITest journey: drag an org item to a folder; it appears there and still shows its organization badge.
- [ ] 4.3 VoiceOver: the folder picker label is "Folder" for both item kinds (§VIII).

## 5. Specs and release (0.25 d)

- [ ] 5.1 CHANGELOG "Fixed": organization items filed in your folders in other Bitwarden apps now show in those folders, and you can file organization items into folders in Prizm.
- [ ] 5.2 Before archiving: repair the structure of `openspec/specs/org-vault-items/spec.md` (add `## Purpose` and `## Requirements`) in a separate commit with no requirement changes. Then replace the folder rule at line 19 and the scenario at lines 31-34 with the requirement from this change.
- [ ] 5.3 `openspec validate org-items-in-personal-folders --type change --strict`.
