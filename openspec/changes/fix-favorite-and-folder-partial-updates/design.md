# Design

## Context

Sources: `$SRC` checkouts of 2026-10-23 (clients, sdk-internal, ios, server) and Vaultwarden tag
1.37.4.

**How official clients change the favorite.**
- Web and browser: `toggleFavorite` flips `favorite` and calls `updateWithServer`
  (`clients/libs/vault/src/services/cipher-action.service.ts:84-89`). That routes to the SDK's full
  `edit` when `cipher.edit` is true and to `edit_partial` otherwise
  (`clients/libs/common/src/vault/services/cipher-sdk.service.ts:78-90`).
- iOS: full update when `cipher.edit`, otherwise `updateCipherPreference`, which is the partial
  endpoint (`ios/BitwardenShared/Core/Vault/Services/CipherService.swift:469-481`).
- So for editable items the official clients send a full PUT. That is safe for them, because the
  SDK models every field and re-sends it. Prizm cannot make that promise for fields it does not
  model yet (see `fix-cipher-edit-data-loss`), or for fields a future server adds.

**Partial endpoint.**
- Official: `PUT /ciphers/{id}/partial` with `{folderId, favorite}` updates only the per-user
  folder and favorite maps (`server/src/Api/Vault/Controllers/CiphersController.cs:898-912`). The
  stored procedure changes `Folders` and `Favorites` and bumps the *account* revision date, not the
  cipher's `RevisionDate` (`server/src/Sql/dbo/Vault/Stored Procedures/Cipher/Cipher_UpdatePartial.sql`).
  It needs only read access to the cipher (`GetByIdAsync`), so it works for read-only items.
- Vaultwarden 1.37.4: `put_cipher_partial` checks that the cipher is accessible and the folder is
  the user's, then calls `move_to_folder` and `set_favorite`
  (`vaultwarden/src/api/core/ciphers.rs:753-783`). Both bump only the user's revision
  (`src/db/models/cipher.rs:506-512`; `src/db/models/favorite.rs:43,53`). The cipher's `updated_at`
  is unchanged.
- Bulk move: `PUT /ciphers/move {ids, folderId}` (SDK `crates/bitwarden-vault/src/cipher/cipher_client/move_many.rs:23-40`).

**Prizm today.**
- `PrizmAPIClient.updateCipherPartial(id:folderId:favorite:)` exists and sends JSON `null` for no
  folder (`Prizm/Data/Network/PrizmAPIClient.swift:963-976`).
- `VaultBrowserViewModel.toggleFavorite` → `vault.update(draft)` (`VaultBrowserViewModel.swift:366-377`),
  errors only logged.
- Local rebuilds without `organizationId`/`collectionIds`: `deleteFolder` (`VaultRepositoryImpl.swift:448-462`),
  `moveItemToFolder` (`:513-524`), `moveItemsToFolder` (`:526-538`). `deleteItem`, `restoreItem`
  and `updateAttachments` already pass all fields (`:357-422`).

## Goals / Non-Goals

**Goals**
- The star never sends encrypted item data.
- No local mutation can drop a `VaultItem` field.
- The cached item stays equal to what the next sync would return, apart from the changed field.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Favorite always uses `/partial`

`setFavorite(itemId:isFavorite:)` sends `PUT /api/ciphers/{id}/partial` with `favorite` and the
item's cached `folderId`, for personal and org items, editable or not.

This deviates from the official clients for editable items (they send a full PUT through the SDK).
Reasons:
- `/partial` exists for exactly these two per-user fields on both servers and is what official
  clients use whenever the full edit is not allowed.
- It cannot drop item data, because it carries none.
- It needs no key, works on read-only items, and does not touch the item's revision.

This reverses the toggle-favorite decision "No new API calls". That decision predates the
`/partial` client (`f464c39`) and assumed the full PUT was lossless.

**Rejected alternative:** keep the full PUT and rely on `fix-cipher-edit-data-loss`. That fix
preserves the fields known today; a favorite click should not depend on it, and the PUT still
fails on read-only items.

### D2. One copy helper for local updates

`VaultItem` gets `func with(folderId: String?) -> VaultItem` and `func with(isFavorite: Bool) ->
VaultItem`. Both call the full memberwise initializer with every stored property. A unit test builds
an item with every property set to a non-default value and checks that only the target property
changes. That test fails at compile time or at run time when someone adds a property and forgets
the helper.

All local rebuilds in this change (`setFavorite`, `moveItemToFolder`, `moveItemsToFolder`,
`deleteFolder`) use the helper. Other existing rebuilds that already pass all fields can move to it
later; that is not required here.

**Rejected alternative:** remove the default arguments from `VaultItem.init`. It would force every
call site to pass all fields, which is good, but touches many tests and files for no extra safety in
this change. Recorded as a follow-up idea.

### D3. Revision date unchanged

After `/partial` and `/move`, the cached `revisionDate` is kept. Neither server changes the
cipher's revision on these calls (see Context). This matters for `fix-cipher-edit-data-loss`,
whose stale-write check sends the cached revision: a new value there would cause false conflicts.

The `/partial` response body is not decoded. Prizm needs nothing from it.

### D4. Use case and error surfacing

`SetFavoriteUseCase` (Domain protocol) and `SetFavoriteUseCaseImpl` (Data) wrap
`VaultRepository.setFavorite`. `VaultBrowserViewModel.toggleFavorite` calls the use case. On
failure it sets `actionError` ("Couldn't update favorite. <reason>"), which the existing alert
shows and VoiceOver announces. On success it refreshes the list and counts as today.

## Risks / Trade-offs

- **[Low] Favorite toggled on a stale `folderId`.** If the item was moved to another folder on
  another device after the last sync, `/partial` writes the old folder back. → Same race exists for
  move-to-folder today; the window ends at the next sync. Official clients send the cached folder
  too.
- **[Low] Deviation from official for editable items** (D1). → Documented; the server state after
  the call is identical.

## Open Questions

1. Should the edit sheet's favorite toggle also move to `/partial` when nothing else changed? Not
   needed for safety once `fix-cipher-edit-data-loss` lands; left for later.
