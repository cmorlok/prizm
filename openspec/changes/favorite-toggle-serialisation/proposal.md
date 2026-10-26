# Proposal

## Why

**Criticality:** P3 (Low: functional)
**Findings:** review of `fix-favorite-and-folder-partial-updates` (2026-10-25), "two fast clicks both
send the same stale `!isFavorite`, so the second is lost". Decided 2026-10-26.

**A second click on the star before the first is saved is lost.**
`VaultBrowserViewModel.toggleFavorite(item:)` sends `!item.isFavorite` for the item the view passed.
The view updates that item only after the server confirmed the first change, so a second click in
between passes the old item again and sends the same value. The user clicked twice (star, unstar)
and ends up with a starred item, in Prizm and on the server.

The same happens with the item list's context menu and with ⌘-key repeats, and across both: the
detail star and the list menu read the same stale item.

### Origin of the current behaviour

- **Pre-existing, accidental.** The toggle has always sent `!item.isFavorite` without tracking
  requests in flight; the partial update of `fix-favorite-and-folder-partial-updates` kept that.

## What Changes

- The last click wins. Each click flips the item's intended state (the intent of a click still
  being saved, else the item's state). At most one request per item is in flight; when it ends and
  the intent differs from what was sent, the intent is sent next.
- A failed request drops the intent and shows the error as today; the next click starts from the
  item's state.
- A lock or sign-out drops all intents; requests from the old session send nothing further.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `toggle-favorite`: fast repeated toggles end in the state of the last click.

## Non-Goals

- Showing the intended state on the star before the server confirms it (optimistic display).
- Folder moves: a move sends the target folder, not a flip, so repeated moves already end in the
  last target.

## Impact

- **Presentation:** `VaultBrowserViewModel` only.
- **Security review:** no (no keys, no new data).

## Estimate

| Step | Scope | Estimate |
|---|---|---|
| 1 | Failing tests, implementation | 0.25 d |
| **Total** | | **0.25 d** |
