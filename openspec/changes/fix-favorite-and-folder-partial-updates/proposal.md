# Proposal

## Why

**Criticality:** P0 (Critical: destroys data now)
**Findings:** W-03, W-12 (`04-write-paths.md`), plus the known move-to-folder bug (K-MOVE)

**One click on the favorite star can delete data.** `toggleFavorite` builds a draft and calls
`VaultRepository.update` (`Prizm/Presentation/Vault/VaultBrowserViewModel.swift:366-377`). That
re-encrypts the item and sends a full `PUT /api/ciphers/{id}`. The full PUT drops every field
Prizm does not model (passkeys, password history and more; see `fix-cipher-edit-data-loss`). So
the star causes the same loss as an edit, without the user ever opening the edit sheet. For org
items it also triggers `PUT /api/ciphers/{id}/collections`. On read-only org items the PUT fails,
and the failure is only logged (`:373-375`).

**Moving items to a folder turns org items into personal items, locally.**
`moveItemToFolder`, `moveItemsToFolder` (`Prizm/Data/Repositories/VaultRepositoryImpl.swift:513-538`)
and `deleteFolder` (`:448-462`) rebuild the cached `VaultItem` without `organizationId` and
`collectionIds`. Until the next sync:
- the item is shown as personal and drops out of its collections in the sidebar;
- editing it sends a PUT with `organizationId` nil, encrypted with the personal vault key. Both
  servers reject that with "Organization mismatch", so the edit fails. Nothing is corrupted on the
  server, but the user cannot save.

### Origin of the current behaviour

- **Favorite via full PUT: deliberate.** The toggle-favorite proposal says "No new API calls — uses
  existing `PUT /ciphers/{id}` via `VaultRepository.update()`"
  (`openspec/changes/archive/2026-03-27-toggle-favorite/proposal.md:9,27`). At that time Prizm had
  no `/partial` client. It was added later (commit `f464c39`) and wired only into move-to-folder.
  The decision was reasonable as a "no new code" shortcut, but it rested on the full PUT being
  lossless. It is not (`fix-cipher-edit-data-loss`), and it fails on read-only items. This change
  reverses that decision; the reasons are recorded in design.md D1.
- **Local rebuild without org fields: accidental.** The `VaultItem` initializer defaults
  `organizationId` to nil and `collectionIds` to `[]` (`Domain/Entities/VaultItem.swift:31-52`), so
  call sites written before org support compile and silently drop them.

## What Changes

- **Favorite uses `/partial`.** Toggling the star sends `PUT /api/ciphers/{id}/partial` with the
  new `favorite` and the item's current `folderId`. No re-encryption, no collections call. It works
  for read-only org items too.
- **Local updates keep every field.** One copy helper on `VaultItem` changes a single field and
  keeps all others. Move to folder (single and bulk), delete folder and favorite use it.
- **Revision date stays.** Neither server bumps the item's revision on `/partial` or `/move`, so
  the cached `revisionDate` is kept as is.
- **Favorite errors are shown.** A failed toggle sets `actionError` (alert) instead of only logging
  (§V).
- The favorite toggle goes through a new Domain use case, so Presentation no longer calls
  `VaultRepository.update` for it (§II).

## Capabilities

### New Capabilities
- `cipher-partial-update`: favorite and folder changes are sent as partial updates and never alter
  other item data, on the server or in the local cache.

### Modified Capabilities
_None in this change._ `openspec/specs/toggle-favorite/spec.md` says only "update the server";
it stays valid. Its source proposal's "No new API calls" note is superseded by this change.

## Non-Goals

- Favorite or folder changes from the edit sheet. They stay in the full PUT, which
  `fix-cipher-edit-data-loss` makes lossless.
- Folders for org items in the edit sheet, and showing org items in personal folders (audit CF-07,
  `org-items-in-personal-folders`).
- Hiding Edit and Delete for read-only items (audit W-14 / CF-09, `honour-org-item-permissions`).

## Dependencies

- None hard. This change does not need `fix-cipher-edit-data-loss`; it removes one path that
  triggers the loss.
- Soft: `honour-org-item-permissions` routes favorite to `/partial` for read-only items only; this
  change does it for all items, so whichever lands first, the other keeps its tests.
- Soft: `fix-collection-assignment` also stops the unconditional collections call; after this
  change the star no longer reaches that code.

## Impact

- **Domain:** `VaultItem` copy helper (`with(folderId:)`, `with(isFavorite:)`);
  `SetFavoriteUseCase` protocol; `VaultRepository.setFavorite(itemId:isFavorite:)`.
- **Data:** `SetFavoriteUseCaseImpl`; `VaultRepositoryImpl` `setFavorite`, `moveItemToFolder`,
  `moveItemsToFolder`, `deleteFolder`. `PrizmAPIClient.updateCipherPartial` is reused unchanged.
- **Presentation:** `VaultBrowserViewModel.toggleFavorite` uses the use case and sets
  `actionError` on failure; `AppContainer` wiring.
- **No new dependencies.**
- **Security review: yes** (vault write path; no key material is used).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Copy helper; fix the four local rebuilds | 0.5 d |
| 2 | Favorite via `/partial`, use case, error surfacing | 0.5–0.75 d |
| 3 | Revision-date and read-only checks on both servers | 0.25–0.5 d |
| 4 | Security review, CHANGELOG | 0.25 d |
| **Total** | | **1.5–2 d** |
