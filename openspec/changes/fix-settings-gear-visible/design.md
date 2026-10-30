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
