# Design

## Context

Sources: `$SRC` checkouts of 2026-10-23 (clients, sdk-internal, server) and Vaultwarden tag 1.37.4.

**No official client has a one-click "Empty Trash".**
- Web vault: in Trash, the user selects items and deletes them. With more than one item this opens
  the bulk delete dialog with `permanent: this.filter.type === "trash"`
  (`clients/apps/web/src/app/vault/individual-vault/vault.component.ts:1460-1476, 1515-1552`).
  The dialog deletes the selected ids (`bulk-action-dialogs/bulk-delete-dialog/bulk-delete-dialog.component.ts:75-87`)
  through `cipherService.deleteManyWithServer` → SDK `delete_many`
  (`clients/libs/common/src/vault/services/cipher.service.ts:1063-1071`).
- SDK `delete_ciphers` sends `DELETE /ciphers` with `{ids, organizationId}`
  (`sdk-internal/crates/bitwarden-vault/src/cipher/cipher_client/delete.rs:30-48`; path in
  `crates/bitwarden-api-api/src/apis/ciphers_api.rs:415-425`).
- The `EmptyTrash` symbol in the web and desktop code is an empty-state illustration, not an action.

**Official server.**
- `DELETE /ciphers` (`CiphersController.cs:1161-1172`): permanently deletes the posted ids that the
  user may delete. On the cloud (not self-hosted) it rejects more than 500 ids. It does not check
  that the items are in Trash.
- `DeleteManyAsync` filters by delete permission and silently skips the rest
  (`server/src/Core/Vault/Services/Implementations/CipherService.cs:446-476`).
- `POST /ciphers/purge` (`CiphersController.cs:1472-1505`) needs the master password hash and
  deletes all of the user's ciphers (`DeleteByUserIdAsync`), or all of an org's when
  `organizationId` is given.

**Vaultwarden 1.37.4.**
- `DELETE /ciphers` with `{ids}` → `delete_multiple_ciphers(..., HardMulti)`
  (`vaultwarden/src/api/core/ciphers.rs:1535-1544`). It deletes one id after the other and stops at
  the first error, for example "Cipher can't be deleted by user" (`:1816-1829`, `:1882-1901`). The
  ids arrive as a `HashSet` (`:1878-1880`), so which items were deleted before the error is
  arbitrary (1.35.4 used a `Vec`). An id deleted elsewhere meanwhile fails the same way ("Cipher
  doesn't exist"). It does not check that items are in Trash either. No size
  limit.
- `POST /ciphers/purge` deletes every cipher the user owns and every folder of the user
  (`ciphers.rs:1752-1776`); `POST /ciphers/purge?organizationId=` purges the org vault for owners
  (`:1710-1750`).
- There is no `DELETE /ciphers/purge` route on either server.

**Prizm today.**
- `PrizmAPIClient.permanentDeleteCipher(id:)` → `DELETE /api/ciphers/{id}`
  (`Prizm/Data/Network/PrizmAPIClient.swift:682-700`).
- `VaultRepositoryImpl.permanentDeleteItem(id:)` removes the item locally after success
  (`Prizm/Data/Repositories/VaultRepositoryImpl.swift:372-382`).
- `TrashView` lists trashed items with per-row Restore and Delete Permanently
  (`Prizm/Presentation/Vault/Trash/TrashView.swift:11-60`).
- No purge code remains (removed in `0a06b74`). A comment still mentions purge in a list of
  "soft-delete, restore, purge" (`PrizmAPIClient.swift:1089`).

## Goals / Non-Goals

**Goals**
- Empty Trash deletes exactly the items that are in Trash on the server at that moment, as far as
  Prizm can know.
- No code path can reach `/ciphers/purge`.
- The user always learns the outcome, including partial failure.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Bulk `DELETE /api/ciphers` with the trashed ids

`permanentDeleteCiphers(ids: [String])` sends `DELETE /api/ciphers` with JSON `{"ids": [...]}`.
`VaultRepository.permanentDeleteItems(ids:)`, called by `EmptyTrashUseCase.execute(ids:)` with the
ids the user confirmed (all items with `isDeleted == true`), sends them in chunks of 500 (the official
cloud limit; harmless on self-hosted servers). `organizationId` is not sent; Prizm uses the
non-admin path.

**Rejected alternative:** `POST /ciphers/purge`. Deletes the whole vault. Never.
**Rejected alternative:** one `DELETE /api/ciphers/{id}` per item. Works on both servers and gives
per-item errors, but N requests and N push notifications for a large trash. Kept as the fallback in
D4 only if task 1.1 shows the bulk call misbehaves.

### D2. Sync before confirming

Neither server checks that the posted ids are trashed. If an item was restored on another device
after Prizm's last sync, a stale list would delete a live item. So the Empty Trash action:
1. runs a sync (existing `SyncUseCase`),
2. computes the trashed ids from the fresh data,
3. shows the confirmation with that count,
4. deletes exactly those ids.

If the sync fails, the action stops with "Couldn't refresh the trash. Try again." and nothing is
deleted.

The remaining window is between step 1 and step 4 (the user reading the dialog). It is the same
window the web vault has between loading the list and confirming.

### D3. Button and confirmation

- Trash toolbar: "Empty Trash" button, destructive styling, disabled when Trash is empty,
  `accessibilityIdentifier` `AccessibilityID.Trash.emptyTrashButton`.
- Confirmation alert: title "Permanently delete N items?", message "This can't be undone.", buttons
  "Delete Permanently" (destructive) and "Cancel" (default).
- Result: the trash list updates; VoiceOver announces "N items permanently deleted" (§VIII).

### D4. Partial failure

After the delete calls (success or error), Prizm syncs again, so the local state matches the server
in both server behaviours (official skips, Vaultwarden stops at the first error).
`EmptyTrashResult {requested, remaining}` is computed from the post-sync trash, and `deleted` is
`requested - remaining`. If the follow-up sync fails, `deleted` is the count the delete calls
reported, and `remaining` comes from the cache. When `remaining > 0`,
the user sees "N items could not be deleted. You may not have permission to delete them." The
underlying error is logged at `.error` with HTTP status only.

### D5. Purge guard

- The API client has no method for any `/purge` path.
- A unit test records every request path built by `PrizmAPIClientImpl` in the test suite's mock
  URL protocol and fails if any ends in `/purge`.
- A source test scans `Prizm/` for the string `ciphers/purge` and fails if it appears outside
  comments that warn against it.
- The comment at `PrizmAPIClient.swift:1089` is corrected.

### D6. After review

- A failing chunk does not stop the others; the first failure is reported at the end. The result
  carries the count the server confirmed, the cause (refused or connection) and whether the
  follow-up sync worked; a failed follow-up sync is not recorded as a sync.
- Lock or sign-out resets the Empty Trash state (`clearSession()`), so the button cannot stay
  disabled and no confirmation comes back in the next session.
- The alert passes its confirmation to the action, so "Delete Permanently" works whether SwiftUI
  closes the alert before or after running it.
- Empty Trash is the first sync that runs in the middle of a session, so a lock can land while it
  runs. `SyncRepositoryImpl` now checks that the vault is still unlocked right before each cache
  and store write, and discards the sync otherwise. A lock between that check and the write it
  guards is not caught (one actor hop).

## Risks / Trade-offs

- **[High → Low] Wrong endpoint wipes the vault.** → D5 guard tests; security review; this design
  documents the purge semantics with source references.
- **[Medium] Stale trash list.** → D2 sync before confirm.
- **[Low] Vaultwarden stops on the first forbidden item**, leaving later items. → D4 reports the
  remainder; the user can delete them one by one or ask an admin.
- **[Low] Large trash.** → Chunks of 500; one sync after all chunks.

## Open Questions

1. Should the confirmation require the master password, as `POST /ciphers/purge` does on the
   server? No official client asks for it for bulk delete of selected items; this design follows
   them.
