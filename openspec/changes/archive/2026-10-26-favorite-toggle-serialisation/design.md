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

`clearSession()` drops the intents but keeps the record of open requests. A request from an ended
session always removes its item from that record when it ends; it shows no error and sends
nothing of its own. If the new session queued a click for that item meanwhile, the click is sent
then. So two requests for one item are never open at once, also across a lock (a lock and a quick
Touch ID unlock while a request hangs), and the last one the server applies is the last click.

The base for a click is the selected item when it is the same item (updated as soon as a change is
confirmed), else the item the view passed (updated after the list refresh).

## Risks / Trade-offs

- **[Low] An edit-sheet save that changes only the folder also sends the favorite state**
  (`/partial`, fix/013), taken from the item when the sheet opened. Star, then ⌘E at once, then a
  folder-only save can undo the star. Pre-existing; the toggle queue does not see edit-sheet saves.

- **[Low] The star shows the confirmed state, not the intent, while requests run.** → As today;
  optimistic display is out of scope.

## Open Questions

_None._
