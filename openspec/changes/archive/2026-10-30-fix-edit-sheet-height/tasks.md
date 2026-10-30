# Tasks

## 1. Fix

- [x] 1.1 Failing UI test: in the organization fixture item's edit sheet, the form's scroll view is at least 300 pt tall (154 pt before: UI run 2026-10-30). Done: red in the diagnostic run `20261030T094451Z` (154 pt); with 720 pt the test failed at 250 pt (`20261030T101027Z`). Green with 800 pt: `20261030T102259Z`; after the review fixes (form found by position, skip below 1000 pt) it passed in the approved UI run `20261030T134942Z` (window over 1000 pt, so not skipped).
- [x] 1.2 `Spacing.editSheetIdealHeight = 800` and the sheet's `idealHeight` (design D1). Done: commit 961bc00f, `DesignSystem.swift:133`, `ItemEditView.swift:133`. Unit tests green (`20261030T100827Z`, 1092 tests; after the squash `20261030T133644Z`).
- [x] 1.3 Hand check in a small window (about 862 pt tall): the sheet fits, Notes and the bottom bar are reachable. Confirmed by Christian on 2026-10-30 with an organization item on the rig: the sheet fits, Save and Discard at its bottom. XCUITest cannot resize the window, so the planned small-window UI test was dropped.

## 2. Release

- [x] 2.1 CHANGELOG "Fixed": the edit sheet is tall enough to show the item's fields. Done: "Fix: the edit and New Item sheets were so short that only about three fields showed, organization items worst. The sheet now asks for 800 pt; in a smaller window it fits the window and the fields scroll."
- [x] 2.2 `openspec validate fix-edit-sheet-height --type change --strict` and `/opsx:verify`. Valid; `/opsx:verify` 2026-10-30: no critical issues; the small-window scenario is covered by the hand check (1.3) only.
- [x] 2.3 Archive the change.
