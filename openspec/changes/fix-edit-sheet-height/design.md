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
