# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies; can ship as a patch release before or together with `fix-cipher-edit-data-loss`.

## 1. Copy helper and local rebuilds (0.5 d)

- [x] 1.1 Failing test: build a `VaultItem` with every property non-default; `with(folderId:)` and `with(isFavorite:)` change only their property (design D2).
- [x] 1.2 Failing tests (mock API): after `moveItemToFolder`, `moveItemsToFolder` and `deleteFolder`, an org item keeps `organizationId`, `collectionIds`, `attachments`, `reprompt` and `revisionDate`. Today these fail.
- [x] 1.3 Implement the helper and use it at `VaultRepositoryImpl.swift:448-462` and `:513-538`.
- [x] 1.4 Failing test: move an org item to a folder, then `update()` it; the PUT body carries `organizationId` and is encrypted with the org key.

## 2. Favorite via `/partial` (0.5–0.75 d)

- [x] 2.1 Failing test (mock API): `setFavorite` sends only `PUT /api/ciphers/{id}/partial` with `favorite` and the cached `folderId` (JSON `null` when none); no cipher PUT, no collections call.
- [x] 2.2 Failing test: `setFavorite` keeps every other cached field and the `revisionDate` (D3).
- [x] 2.3 Add `VaultRepository.setFavorite`, `SetFavoriteUseCase` (Domain) and `SetFavoriteUseCaseImpl` (Data); wire in `AppContainer`.
- [x] 2.4 Failing view-model test: `toggleFavorite` calls the use case; on failure `actionError` is set and the item is unchanged.
- [x] 2.5 Switch `VaultBrowserViewModel.toggleFavorite` to the use case. §VII comment at the call site explaining why `/partial` is used (D1).

## 3. Server checks (0.25–0.5 d)

- [ ] 3.1 On the rig (Vaultwarden 1.37.4) and Bitwarden self-hosted if available: toggle favorite on an item with a passkey created in the extension; confirm the passkey survives. Toggle favorite on a read-only org item; confirm success. Confirm that the cipher's `revisionDate` in `/sync` is unchanged after both calls. Record the results in design.md, Context.

## 4. Release (0.25 d)

- [ ] 4.1 Mandatory security review: the star path sends no encrypted data and no key is loaded; no item names in logs.
- [x] 4.2 CHANGELOG "Fixed": the favorite star no longer re-saves the whole item (which could remove passkeys or password history) and now works on view-only organization items; moving organization items to a folder no longer makes them look personal or breaks the next edit. "Changed": a failed favorite toggle now shows an error.
- [x] 4.3 `openspec validate fix-favorite-and-folder-partial-updates --type change --strict`.

## Results (2026-10-25)

- `VaultItemCopyTests`, `PartialUpdateTests` (repository and request body, `URLProtocol` stub),
  `ToggleFavoriteTests` (rewritten: the old tests asserted the full update this change replaces).
  They fail before the change (compile, then behaviour) and pass after; `PrizmTests` passed.
- Also fixed: `moveItemToFolder` reused the array index from before its network call. The repository
  is an actor and reentrant, so a sync in between could make it update the wrong item or crash; it
  now looks the item up again, as `setFavorite` does.
- After review: the `/partial` response is checked (Bitwarden's EF backends answer 200 without
  saving), the cache takes the pair that was sent, a lock during the request is no error, the copy
  helpers copy `self` (`VaultItem.folderId`/`isFavorite` are `private(set) var`;
  `VaultItem(_ draft:)` now delegates to the main initializer). Tests for each, including the
  reentrancy case. `PrizmTests`: 595 passed.
- Open: 3.1 needs the rig (passkey survives the star, read-only org item, revision unchanged), plus
  Bitwarden self-hosted with an EF backend. Decision needed: design.md, Open Questions 0.

