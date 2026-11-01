# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-cipher-edit-data-loss` (merged).

## 1. Confirm semantics (0.5 d)

- [x] 1.1 Semantics confirmed from sdk-internal `c1c9b9a5` (`cipher.rs:1009-1027`, `login.rs:387-413`, `field.rs:126-158`, `password_history.rs:13,93-105`) and recorded in design.md, Context: cap 5, `"<name>: <value>"`, rename = removal, empty old password skipped, order reversed then prepended.

## 2. Model and on-demand decryption (1–1.5 d)

- [x] 2.1 Domain: add `LoginContent.passwordRevisionDate: Date?`, `VaultItem.passwordHistoryCount: Int`, the `PasswordHistoryEntry` entity, and the `GetPasswordHistoryUseCase` protocol. Done in the data commit; red 20261030T201113Z (compile), green 20261030T201312Z (1393).
- [x] 2.2 `CipherMapper` maps the count and the revision date only, never history values. Mapper tests: absent, `null`, empty array, array with a non-object element, non-array value (count 0). Done: `PasswordHistoryTests` (count cases), `PasswordRevisionDateTests`.
- [x] 2.3 `GetPasswordHistoryUseCaseImpl` (design D1): stored record + token, `effectiveKeys` + `verifyKey`, no fallback. Tests: personal item, org item, per-cipher-key item, locked vault (`vaultLocked`), lock during the load (dropped), an element that does not decrypt or has no `password` ("could not be read"; the others still show), an unparsable date ("Unknown date"). Done: `PasswordHistoryTests`; the org-read and missing-org-key cases were added after the code review (R3, green 20261031T080312Z, 1404).

## 3. Record history on save (1–1.5 d)

- [x] 3.1 `PasswordHistoryPolicy.newEntries(oldPassword:newPassword:oldHidden:newHidden:)` (pure Domain). Table-driven tests: password changed, cleared, unchanged, old password empty; hidden field changed, removed, renamed, empty name or value ignored; hidden field on a card or secure note; text, boolean and linked fields ignored; order of several new entries (design Context). Done: `PasswordHistoryPolicyTests` (card removal, boolean and linked cases added at review R3).
- [x] 3.2 `CipherMapper.toRawCipher` (design D2): originals from `base`, one `now` for the date and the entries; encrypt, prepend, keep 5. Tests: existing elements byte-identical (also non-object ones); cap; order; absent/`null` history starts an array; non-array value unchanged and no entry; cleared password recorded; first password only sets the date; org item and per-item-key item; a retry after `collectionChangeNotSaved` adds no second entry; a folder- or favourite-only edit (`/partial`) leaves the history unchanged; a lock during the save sends nothing. Done: `PasswordHistoryTests`, `EditOverlayTests`; the retry is covered by the double-save test (verify S4); a lock during the save is covered by the existing update tests (`VaultRepositoryImpl` token check before the request; no new test).
- [x] 3.3 Test only (already implemented by `storeRecord`): the stored record and `passwordHistoryCount` are refreshed from the server response after a save. Done: count-after-save test (review R3), passed as a characterisation test.

## 4. History sheet (1.5–2 d)

- [x] 4.1 `PasswordHistoryViewModel`: load through the use case on appear, empty the array on dismiss and on `.vaultDidLock`, drop a result that arrives after either, sort by date (newest first, ties keep array order). Tests for each. Done: `PasswordHistoryViewModelTests`; red 20261030T201511Z, green 20261030T201736Z (1401). Security review LOW-1: the lock observer now dismisses in the notification's own main-actor turn (`MainActor.assumeIsolated`), test included; the repository-side window is gap 7 of `lock-state-machine`.
- [x] 4.2 `PasswordHistorySheet`: masked rows with `MaskedFieldView`, Option peek, dates, copy with the user's clipboard clear delay, "Entry could not be read" rows, Close/Esc. Identifiers by row index. Design tokens only. Done. Security review LOW-2: rows in a lazy stack; more than 10 rows scroll at the fixed height `Spacing.historyListMaxHeight` (`PasswordHistoryViewModel.scrolls(rowCount:)`, `testLongHistory_scrolls_usualOneDoesNot`; green 20261031T175648Z, 1406).
- [x] 4.3 VoiceOver: labels, values and hints as in design.md D3, and the header trait. ~~Add an XCUITest that opens the sheet and checks the accessibility labels.~~ Done by hand instead: the XCUITest `PasswordHistoryJourneyTests` found and clicked the footer link but never saw the sheet in the accessibility tree in four approved UI runs (2026-10-31, also with the sheet attached to the pane); Christian chose to drop it. Hand checks (Christian, 2026-10-31, VoiceOver, Debug build): the sheet opens with its entry, rows read "History entry from <date>, hidden", reveal and copy work, switching items and locking close it.

## 5. Footer (0.5 d)

- [x] 5.1 "Password updated" row (only when a date exists) and "Password history: N" button (only when N > 0) in `ItemDetailView.metadataFooter`, through `ItemFooterModel` (unit tests for the rules) and `Spacing.footerLabelWidth` (the longest label does not truncate; UI check). Update the `detail-card-view` spec scenarios. Done; footer label checked untruncated in the hand check above; `detail-card-view` delta in this change.

## 6. Verify and document (0.5 d)

- [x] 6.1 Interop on the rig (Vaultwarden 1.37.4): change a password and a hidden field in Prizm and check with the official `bw` CLI that the history holds both entries in the official format; change the password with `bw` and check that Prizm's sheet shows it. The web-vault UI is a documented gap (`bw` stands in). Done: batch-3 rig run 20261031T081759Z, all PASS (bw 2026.9.1).
- [x] 6.2 Mandatory security review: no values in logs, cleared on lock and dismiss, and no decryption at sync. Done: fresh reviewer, 2026-10-31: 0 high/medium, 2 LOW, both fixed (4.1, 4.2).
- [x] 6.3 SECURITY.md (history in memory only while viewed), ACCESSIBILITY.md, CHANGELOG "Added: password history". README: remove password history from "Known Limitations" if listed there. Done: docs commit (README feature line, SECURITY.md "Password History", ACCESSIBILITY.md 4.1.2 remark); README did not list it as a limitation; CHANGELOG in the archive commit.
- [x] 6.4 `openspec/specs/detail-card-view/spec.md` has `## Purpose` / `## Requirements` (repaired by fix/000) and validates strictly (checked 2026-10-30).
- [x] 6.5 `openspec validate password-history --type change --strict`, then confirm `openspec archive password-history` would apply the `detail-card-view` delta. Done in the archive commit.
