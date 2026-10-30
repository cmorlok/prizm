# Tasks

## 1. Fix

- [ ] 1.1 Failing UI test: in the organization fixture item's edit sheet, the form's scroll view is at least 300 pt tall (154 pt before: UI run 2026-10-30).
- [ ] 1.2 `Spacing.editSheetIdealHeight = 800` and the sheet's `idealHeight` (design D1).
- [ ] 1.3 Hand check in a small window (about 862 pt tall): the sheet fits, Notes and the bottom bar are reachable.

## 2. Release

- [ ] 2.1 CHANGELOG "Fixed": the edit sheet is tall enough to show the item's fields.
- [ ] 2.2 `openspec validate fix-edit-sheet-height --type change --strict`.
