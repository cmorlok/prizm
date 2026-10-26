# Design

## Context

`toggleFavorite(item:)` starts a task that calls `SetFavoriteUseCase.execute(itemId:isFavorite: !item.isFavorite)`
and, on success, `handleItemSaved` updates the selection and refreshes the list. Requests run in
parallel. `fix-favorite-and-folder-partial-updates` made the repository cache exactly the pair the
server confirmed, so the server and the cache agree with the last request that finished.

## Decisions

### D1. Intent per item, one request in flight per item

`favoriteIntent: [itemId: Bool]` and `favoriteInFlight: Set<itemId>`:
- click: `intent = !(favoriteIntent[id] ?? item.isFavorite)`, store it; if no request for the item
  is in flight, send it
- request done (success): if the stored intent differs from the sent value, send the intent;
  otherwise drop it
- request failed: drop the intent, show the error (as today)

Serialising per item makes the last request sent the last one the server applies, so the server,
the cache and the star end in the last click's state. Requests for different items still run in
parallel.

**Rejected alternative:** ignore clicks while a request is in flight. Two clicks would then end
starred, which is the bug the user sees.

### D2. Session end

`clearSession()` clears both maps. A task that finishes after the session ended touches neither map
and sends nothing further (`isCurrent(generation)`), so a request from before a lock can't disturb
the next session's state.

## Risks / Trade-offs

- **[Low] The star shows the confirmed state, not the intent, while requests run.** → As today;
  optimistic display is out of scope.

## Open Questions

_None._
