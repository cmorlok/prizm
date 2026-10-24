# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-cipher-edit-data-loss` (merged).

## 1. Confirm semantics (0.5 d)

- [x] 1.1 Semantics confirmed from sdk-internal `c1c9b9a5` (`cipher.rs:1009-1027`, `login.rs:387-413`, `field.rs:126-158`, `password_history.rs:13,93-105`) and recorded in design.md, Context: cap 5, `"<name>: <value>"`, rename = removal, empty old password skipped, order reversed then prepended.

## 2. Model and on-demand decryption (1–1.5 d)

- [ ] 2.1 Domain: add `LoginContent.passwordRevisionDate: Date?`, `VaultItem.passwordHistoryCount: Int`, the `PasswordHistoryEntry` entity, and the `GetPasswordHistoryUseCase` protocol.
- [ ] 2.2 `CipherMapper` maps the count and the revision date only, never history values. Mapper tests: absent, `null`, empty array, array with a non-object element, non-array value (count 0).
- [ ] 2.3 `GetPasswordHistoryUseCaseImpl` (design D1): stored record + token, `effectiveKeys` + `verifyKey`, no fallback. Tests: personal item, org item, per-cipher-key item, locked vault (`vaultLocked`), lock during the load (dropped), an element that does not decrypt or has no `password` ("could not be read"; the others still show), an unparsable date ("Unknown date").

## 3. Record history on save (1–1.5 d)

- [ ] 3.1 `PasswordHistoryPolicy.newEntries(oldPassword:newPassword:oldHidden:newHidden:)` (pure Domain). Table-driven tests: password changed, cleared, unchanged, old password empty; hidden field changed, removed, renamed, empty name or value ignored; hidden field on a card or secure note; text, boolean and linked fields ignored; order of several new entries (design Context).
- [ ] 3.2 `CipherMapper.toRawCipher` (design D2): originals from `base`, one `now` for the date and the entries; encrypt, prepend, keep 5. Tests: existing elements byte-identical (also non-object ones); cap; order; absent/`null` history starts an array; non-array value unchanged and no entry; cleared password recorded; first password only sets the date; org item and per-item-key item; a retry after `collectionChangeNotSaved` adds no second entry; a folder- or favourite-only edit (`/partial`) leaves the history unchanged; a lock during the save sends nothing.
- [ ] 3.3 Test only (already implemented by `storeRecord`): the stored record and `passwordHistoryCount` are refreshed from the server response after a save.

## 4. History sheet (1.5–2 d)

- [ ] 4.1 `PasswordHistoryViewModel`: load through the use case on appear, empty the array on dismiss and on `.vaultDidLock`, drop a result that arrives after either, sort by date (newest first, ties keep array order). Tests for each.
- [ ] 4.2 `PasswordHistorySheet`: masked rows with `MaskedFieldView`, Option peek, dates, copy with the user's clipboard clear delay, "Entry could not be read" rows, Close/Esc. Identifiers by row index. Design tokens only.
- [ ] 4.3 VoiceOver: labels, values and hints as in design.md D3, and the header trait. Add an XCUITest that opens the sheet and checks the accessibility labels.

## 5. Footer (0.5 d)

- [ ] 5.1 "Password updated" row (only when a date exists) and "Password history: N" button (only when N > 0) in `ItemDetailView.metadataFooter`, through `ItemFooterModel` (unit tests for the rules) and `Spacing.footerLabelWidth` (the longest label does not truncate; UI check). Update the `detail-card-view` spec scenarios.

## 6. Verify and document (0.5 d)

- [ ] 6.1 Interop on the rig (Vaultwarden 1.37.4): change a password and a hidden field in Prizm and check with the official `bw` CLI that the history holds both entries in the official format; change the password with `bw` and check that Prizm's sheet shows it. The web-vault UI is a documented gap (`bw` stands in).
- [ ] 6.2 Mandatory security review: no values in logs, cleared on lock and dismiss, and no decryption at sync.
- [ ] 6.3 SECURITY.md (history in memory only while viewed), ACCESSIBILITY.md, CHANGELOG "Added: password history". README: remove password history from "Known Limitations" if listed there.
- [x] 6.4 `openspec/specs/detail-card-view/spec.md` has `## Purpose` / `## Requirements` (repaired by fix/000) and validates strictly (checked 2026-10-30).
- [ ] 6.5 `openspec validate password-history --type change --strict`, then confirm `openspec archive password-history` would apply the `detail-card-view` delta.
