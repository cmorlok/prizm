# Design

## Context

UI run 2026-10-30 (`batch/1-ui-run`, diagnostic test, window 1878 × 1170 pt): toolbar items were
"Hide Sidebar", two empty groups, "more toolbar items", "New Item" and "Search"; no element with
the identifier `vault.settings`. The window controls end at about 80 pt and the sidebar toggle at
about 136 pt from the window's left edge; the sidebar column was 190 pt wide. A 44 pt toolbar
button plus spacing does not fit.

## Decisions

### D1. Widen the sidebar column, keep the placement

`navigationSplitViewColumnWidth(min: 220, ideal: 240)`. 220 pt leaves room for the gear after the
toggle with the standard toolbar spacing. The list column keeps its own widths.

**Rejected alternative:** `.primaryAction` or the detail toolbar. It undoes the maintainer's
placement (01d12926) and moves Settings away from the window's leading edge.

**Rejected alternative:** `ToolbarItem(placement: .navigation)` without a width change. Same
column, same overflow.

### D2. Spec follows the code

The requirement and its scenario name the sidebar toolbar and require the gear to be visible
without the overflow menu.

## Risks / Trade-offs

- **[Low] The list and detail columns lose up to 30 pt.** On a 1280 pt wide window the detail
  column still has more than 700 pt.
- **[Low] A future macOS toolbar change can overflow it again.** The UI test catches that.

## Review

Independent review on 2026-10-30 (fresh reviewer, read-only, diff against `develop`), three findings,
no blocker:
- Fixed: the narrow-sidebar UI test dragged the divider a fixed 150 pt, so a sidebar restored wider
  than about 370 pt would never reach the minimum. It now drags by the sidebar's full width.
- Fixed: task 1.3 still called the check a hand check although a UI test now does it. The task
  names the test.
- Declined: the column widths `min: 220, ideal: 240` are literals, not design tokens. The list
  column uses the same pattern, and the design system's tokens cover spacing and typography, not
  column widths.

The reviewer also noted that the two "Settings opens" scenarios (⌘, and clicking the gear) have no
automated test. They were untested before; this change only rewords where the gear sits.

No security-relevant code is touched: one column width and one UI test.
