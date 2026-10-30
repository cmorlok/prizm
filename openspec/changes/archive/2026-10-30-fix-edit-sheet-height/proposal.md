# Proposal

## Why

The edit sheet of an organization item is too short. Found in the milestone-1 UI checks
(05-07-SUMMARY: a 770 pt sheet for about 855 pt of content, Notes under the bottom bar) and measured
again in the UI run of 2026-10-30: in a window 1170 pt tall the sheet was 480 × 610 pt, and the
scrolling form under the fixed header (name, collections, folder) had 154 pt, about three rows.

The sheet takes the ideal height of its content. Only the form below the header scrolls, and a
`ScrollView` asks for almost no height, so the sheet ends up as small as its fixed parts allow. An
organization item has the tallest fixed header, so it is hit hardest; personal items get a small
sheet too.

## What Changes

- The edit sheet asks for an ideal height of 800 pt (new token `Spacing.editSheetIdealHeight`), so
  the form gets room; macOS still fits the sheet into a smaller window, and the form scrolls.

## Capabilities

### New Capabilities
- `edit-sheet-layout`: the size of the edit and create sheet.

## Non-Goals

- Moving the collection or folder cards into the scrolling form.
- A resizable sheet.

## Dependencies

None. `fix-collection-assignment` makes the collections card taller but caps its list
(`Spacing.collectionListMaxHeight`); both changes touch different lines of `ItemEditView`.

## Impact

- **Presentation:** `ItemEditView` frame; `DesignSystem.swift` token.
- **Tests:** a UI test measures the form's height for the organization fixture item.
