# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
Groups 1–4 have no prerequisites. Group 5 requires `fix-cipher-edit-data-loss` and
`fix-read-mapping-lossless-fields` (both merged), so the custom-field controls need no build flag.

## 1. Search (1 d)

- [ ] 1.1 Failing tests for `VaultSearchMatcher` (Domain): term splitting, AND across fields, case and diacritic folding ("muller" finds "Müller"), every target in the D2 table, "4111" finds nothing for a card ending 1111, empty query matches all.
- [ ] 1.2 Implement `VaultSearchMatcher`; replace `VaultItem.matchesSearch` in `VaultRepositoryImpl`. Update with a reason `SearchVaultTests.testSearchSSHKey_doesNotMatchFingerprint` and `testSearchSecureNote_matchesNameOnly` (`SearchVaultTests.swift:138-151`), which contradict this change.
- [ ] 1.3 Failing test: `ranges(of:in:)` returns every match of every term in name and subtitle, diacritic-insensitive; highlighting uses it; a secure-note subtitle match is highlighted; a match only in the hidden part of the notes has none. Update `HighlightedTextTests.swift` (the signature changes).
- [ ] 1.4 `measure {}` test: 5,000 generated items, one query, with a generous bound; record the developer-Mac number in design.md by hand.

## 2. No Folder and My Vault (0.75 d)

- [ ] 2.1 Failing tests: `buildIndexes` fills `.noFolder` (active, no `folderId`) and `.myVault` (active, no `organizationId`); counts match.
- [ ] 2.2 Add both `SidebarSelection` cases in `displayName`, `==` and `hash` (11, 12), with tests modelled on `SidebarSelectionTests.swift:12-24` (each case equals only itself, distinct hashes). Sidebar rows via `SidebarRowView` (count badge, SF Symbols, accessibility identifiers; no drop target, no context menu). "My Vault" only when the user has an organization; "No Folder" only when the user has a folder; the selection falls back to All Items when its row disappears (VM tests for each rule).
- [ ] 2.3 XCUITest with `--ui-test-org-folders` plus one flag-gated personal item in "Work", so "No Folder" and "My Vault" list different items: select each row and check the list.

## 3. Trees (0.25 d)

- [ ] 3.1 Failing tests: "Work/A" and "work/B" give two parents in `FolderTreeNode` and `CollectionTreeNode`; virtual parents stay non-selectable; two folders with the identical name both appear. Update `CollectionTreeNodeTests` where they expect merging by case.
- [ ] 3.2 Switch segment comparison to `==`; fix the comment that claims to mirror Bitwarden's convention (`CollectionTreeNode.swift:5-6`).

## 4. Sorting (0.25 d)

- [ ] 4.1 Failing tests: "Server 2" before "Server 10"; equal-named logins ordered by username (nil as ""); equal non-logins keep sync order; tree siblings, folders, organizations and collections use the same order. Update `VaultRepositoryImplTests.testAllItems_sortsCaseInsensitive` (`:104`) if its expectation changes.
- [ ] 4.2 Implement D5 in `VaultRepositoryImpl.sorted`, `folders()`, `organizations()`, `collections()` and the tree builders.

## 5. Custom fields (2–2.5 d)

- [ ] 5.1 Failing tests (`DraftVaultItem`, `ItemEditViewModel`): add, rename, remove, move; draft-only ids left out of `==` (opening and cancelling without edits gives `hasChanges == false`; a folder-only change still goes through `/partial`); type immutable; a new field needs a name; a named field cleared to empty blocks Save; a nameless field typed and cleared goes back to nil; unknown-type fields can be moved, removed and renamed.
- [ ] 5.2 Failing test (`CipherMapper.toRawCipher`): field order and names in the request follow the draft; names and values are encrypted with the effective key; a nameless field read from the server is kept; a renamed field keeps its unknown keys; a new field named like a removed one gets none.
- [ ] 5.3 Failing test: `LinkedFieldId.options(for:)` lists only the item type's linkable targets; the first is preselected; picking another target changes the saved `linkedId`.
- [ ] 5.4 `CustomFieldsEditSection`: always visible, "Add Field" menu, row controls as in `URIEditRow`, linked Picker, VoiceOver labels per field; the move announcement text from a unit-tested function. DesignSystem tokens only. Update the stale comments at `CustomFieldsEditSection.swift:5-11` and `DraftVaultItem.swift:49-58, :82`.
- [ ] 5.5 Read-only hidden fields: recorded as a requirement for `honour-org-item-permissions` (not merged); nothing to build here.
- [ ] 5.6 Whichever of this change and `password-history` lands second: failing test that removing, renaming or changing a hidden field appends `"<name>: <old value>"`.
- [ ] 5.7 XCUITest, sheet only (always runs): add a field, rename, reorder, remove, Save disabled while a new field's name is empty. Save and reopen run under `UITestPrerequisite.serverWrites()` or on the rig (5.8).
- [ ] 5.9 VoiceOver hand check: field labels, Move Up/Down, the move announcement.
- [ ] 5.8 Interop check on the rig (Vaultwarden 1.37.4): fields added and reordered in Prizm appear in the same order with the official `bw` CLI; the web-vault UI is a documented gap.

## 6. Release (0.5 d)

- [ ] 6.1 README "Known Limitations": clone, bulk delete/restore, TOTP seed editing not available; mention multi-term search under Shortcuts/Search if a search section exists.
- [ ] 6.2 Note in the PR that no security review is needed (no crypto, keys or tokens changed; custom-field writes use the reviewed save path).
- [ ] 6.3 CHANGELOG "Added": "No Folder" and "My Vault" views; add, rename, remove and reorder custom fields. "Changed": search matches several words, ignores accents and also searches notes, card brand and last digits, identity names and SSH fingerprints; lists sort numbers naturally; folders differing only in case are no longer merged.
- [ ] 6.4 `openspec validate vault-browsing-parity --type change --strict`.
