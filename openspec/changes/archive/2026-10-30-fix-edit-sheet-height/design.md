# Design

## Context

`ItemEditView` is a `VStack`: error banner, name, collection card (org items), folder card, then
the type form in a `ScrollView`, then the bottom bar. Its frame is
`.frame(minWidth: 480, minHeight: 400)` with no ideal height. On macOS a sheet takes its content's
ideal size; a `ScrollView`'s ideal height is close to zero, so the sheet is about as tall as the
fixed parts.

UI run 2026-10-30 (diagnostic test, `--ui-test-org-folders`, item "Omega Shared"): window
1878 × 1170, sheet 480 × 610, form scroll view 154 pt tall.

## Decisions

### D1. An ideal height for the sheet

`.frame(minWidth: 480, minHeight: 400, idealHeight: Spacing.editSheetIdealHeight)` with
`editSheetIdealHeight = 800`. 800 pt fits the smallest supported layout (the 862 pt tall window of
the milestone-1 runs) and gives the form of an organization item more than 300 pt. Measured: the
header, card and bars of the organization fixture take about 470 pt; 720 pt left the form 250 pt
(UI run 2026-10-30, second run). In a smaller
window macOS limits the sheet to the window and the form scrolls.

**Rejected alternative:** move the cards into the scrolling form. It changes what stays visible
while scrolling, which the spec of the collection picker (`fix-collection-assignment`) relies on.

## Risks / Trade-offs

- **[Low] A personal item with few fields gets more empty space.** The bottom bar stays at the
  bottom; the form is top-aligned.

## Review

Independent review on 2026-10-30 (fresh reviewer, read-only, diff against `develop`), five findings,
no blocker:
- Fixed: the 300 pt check ran only in a window at least 1000 pt tall and otherwise passed without
  checking anything. It now skips with the measured window and form heights.
- Fixed: the form was the sheet's last scroll view by index, which could pick another scroll view.
  It is now the lowest scroll view by position. An accessibility identifier on the form was not
  used: in this app an identifier on a container passes down to its children.
- Fixed: the test now waits for the Edit button before it clicks it.
- Fixed: the fix commit said 720 pt after the value had become 800 pt; reworded when the branch
  was squashed.
- Declined: the assertion that the sheet is no taller than the window can hardly fail. It is kept
  as a cheap guard for the "fits the window" part of the requirement; the small window itself is
  covered by the hand check (task 1.3).

The same `ItemEditView` serves the edit and the New Item sheet (`ItemDetailView.swift:96`,
`VaultBrowserView.swift:320`), so both get the height; the UI test opens only the edit sheet.

No security-relevant code is touched: one design token, one frame and one UI test.
