# Design

## Context

Sources: `$SRC` checkouts of 2026-10-23 (clients, sdk-internal, server) and Vaultwarden tag 1.37.4.

**Web cipher form (official).**
- `collectionIds` is a required multi-select (`clients/libs/vault/src/cipher-form/components/item-details/item-details-section.component.ts:77`).
- Non-admins can pick only collections that are `assigned && !readOnly` (`:486-494`).
- Read-only collections the item is already in are collected in `readOnlyCollections` (`:397-403`),
  shown as a note ("cannotRemoveViewOnlyCollections", `item-details-section.component.html:61-63`)
  and always added back to the saved list (`:179-182`).
- The control is disabled when the user may not assign collections for this item (`:410-434`).
- On save, the form compares the original and new collection sets. If they are equal it only
  updates the cipher. If they differ it first updates the cipher with the *original* collections,
  then saves the new collections in a second call
  (`clients/libs/vault/src/cipher-form/services/default-cipher-form.service.ts:49-103`).

**SDK.** `update_collection` sends `PUT /ciphers/{id}/collections_v2` and reads an optional cipher
from the response (`sdk-internal/crates/bitwarden-vault/src/cipher/cipher_client/edit.rs:469-498`;
endpoint in `crates/bitwarden-api-api/src/apis/ciphers_api.rs:1008-1018`).

**Official server.**
- `PUT /ciphers/{id}/collections_v2` returns `{unavailable, cipher}`. `unavailable` is true when the
  user lost access through the change. It answers 404 when the cipher's `ViewPassword` is false
  (`server/src/Api/Vault/Controllers/CiphersController.cs:982-1008`). The legacy
  `PUT /ciphers/{id}/collections` has no such check (`:955-973`).
- `SaveCollectionsAsync` (`server/src/Core/Vault/Services/Implementations/CipherService.cs:717-753`)
  calls `CollectionCipher_UpdateCollections`. That procedure adds posted collections the user can
  write and removes the item from every writable collection that is *not* posted. Read-only
  collections are neither added nor removed (`server/src/Sql/dbo/Stored Procedures/CollectionCipher_UpdateCollections.sql`).
  It logs `Cipher_UpdatedCollections` and sends a push every time.
- Org create: `POST /ciphers/create` checks that every posted collection is writable
  (`CiphersController.cs:353-371`, `CanEditItemsInCollections` `:865-890`). An empty list passes
  that check and creates an item with no collection (`CipherService.cs:135-142`).
- `/sync` returns collections as `CollectionDetailsResponseModel` with `readOnly`, `hidePasswords`
  and `manage` (`server/src/Api/Vault/Models/Response/SyncResponseModel.cs:63-64`;
  `server/src/Api/AdminConsole/Models/Response/CollectionResponseModel.cs:41-59`).

**Vaultwarden 1.37.4.**
- `collections_v2` exists and wraps the legacy handler: `{object: "optionalCipherDetails",
  unavailable: false, cipher}` (`vaultwarden/src/api/core/ciphers.rs:792-817`).
- The handler first refuses items not in an editable collection of the user ("Collection cannot be
  changed", `:844-846`). It then walks the symmetric difference between posted and current
  collections. For each, it adds or removes when the collection is writable, and otherwise fails
  the whole request with "No rights to modify the collection" (`:855-873`).
- **Rig result (task 1.1, 2026-10-30, Vaultwarden 1.37.4, member B with writable W1/W2 and
  read-only R; item in W1 and R; `.planning/batch1/rig.mjs setup`):** posting `[W1, R, W2]` →
  400 "No rights to modify the collection", item stays in W1, R; posting `[W1, W2]` (R left out)
  → 200, `unavailable: false`, cipher in the body, item in W1, W2, R; posting the unchanged
  `[W1, R]` → 400 "No rights to modify the collection". So the source reading above was wrong
  about unchanged read-only collections: any read-only id in the list fails the request, and a
  read-only assignment that is left out is kept. Prizm therefore leaves read-only (and unknown)
  ids out of the request (D2). The Prizm live check confirmed it: before the change, adding W3 to
  an item in W1 and R failed with "the collection change failed" while Vaultwarden had still
  added W3 (it does not roll back).
- Org create with no collections fails for members without full access
  (`ciphers.rs:484-503`: "You don't have permission to add cipher directly to organization").
- Sync collections carry `readOnly`, `hidePasswords`, `manage` (`src/db/models/collection.rs:99-153`).

**Older servers.**
- Vaultwarden has `collections_v2` from 1.32.0 at least (`src/api/core/ciphers.rs:713` at tag
  1.32.0; `:727` at 1.34.0).
- The official server added `collections_v2` in v2024.6.0 (`src/Api/Vault/Controllers/CiphersController.cs:626-627`
  at v2024.6.0). v2024.1.0 to v2024.5.0 have only `PUT /ciphers/{id}/collections`
  (`CiphersController.cs:290-291` at v2024.1.0). Prizm logs in to those versions today (they serve
  `POST /identity/accounts/prelogin`, `src/Identity/Controllers/AccountsController.cs:72` at
  v2024.1.0), and today's collections call works there.
- A route that does not exist answers 404 with an empty body (ASP.NET Core routing) or 405. A
  `NotFoundException` from the controller (for example hidden passwords, or no access) answers 404
  with an error body (`ErrorResponseModel`, "Resource not found.").

**Prizm today.**
- `ItemEditView.swift:56-97`: single `Picker` with "None", listing all collections of the org.
  Choosing one replaces every same-org id with that one.
- `ItemEditViewModel.swift:202-216` and `App/AppContainer.swift:280-300`: create mode pre-fills one
  collection from the sidebar context; "None" is selectable.
- `VaultRepositoryImpl.swift:529-576` (since `fix-cipher-edit-data-loss`): after the cipher PUT, an
  unconditional `updateCipherCollections` for org items; its answer becomes the stored record. If it
  fails, the saved item is kept with the collections the PUT reports, the record is refreshed and
  `VaultError.collectionChangeNotSaved` is thrown ("Your changes were saved, but the collection
  change failed. Try again."); the edit sheet keeps the draft and moves its base to the saved
  revision (`ItemEditViewModel.moveBaseToSavedItem`).
- `PrizmAPIClient.swift:89-106, 834-847`: legacy `/collections`, with the false "Default collection"
  comment.
- `RawCollection` decodes `id`, `organizationId`, `name` only (`SyncResponse.swift:134-157`);
  `OrgCollection` has the same three fields (`Domain/Entities/OrgCollection.swift:9-13`).

## Goals / Non-Goals

**Goals**
- Saving an org item never removes a collection assignment the user did not uncheck.
- The request never contains a collection the last sync lists as read-only for the user, and never
  omits one that may be writable (unknown collections are sent back).
- A collection change another member made while the sheet was open is not undone.
- An org item always has at least one collection.
- No collections request when the set did not change.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Decode collection permissions

`RawCollection` gains `readOnly`, `hidePasswords` and `manage` (default `false` when absent, both
key casings). `OrgCollection` gains `readOnly`. `hidePasswords` and `manage` stay in Data until the
`honour-org-item-permissions` needs them. That change decodes the same three fields (its task 1.3);
whichever change lands first adds the decoding, and the other reuses it.

### D2. One pure function builds the final list

`CollectionAssignment.finalIds(original:selectedWritable:writableIds:)` in Domain (Foundation
only):

- `kept` = ids in `original` that are not in `writableIds` (read-only collections, collections of
  other orgs, ids Prizm does not know). They are always kept.
- result = `kept` ∪ `selectedWritable`, in a stable order (original order first, then new ids).

The view only toggles membership in `selectedWritable`. The view never builds the list itself.

The result is the item's collection list in Prizm. The **request** leaves out the collections the
last sync lists as read-only: `VaultRepositoryImpl.requestCollectionIds` filters them before
calling `collections_v2`. They stay assigned on both servers: the official procedure changes only
writable assignments, and Vaultwarden keeps a left-out read-only assignment but refuses any
read-only id in the list (rig result in Context). Unknown ids (a collection whose name did not
decrypt, so the sync dropped it) are sent back: one may be writable, and leaving it out would make
the server remove it. If one is read-only, Vaultwarden refuses the request and the D5 error path
runs, which loses nothing.
Table-driven unit tests cover the cases.

**Rejected alternative:** keep the single picker and only preserve the other ids. It still cannot
express "add to a second collection", and the official clients use a multi-select.

### D2a. Apply the user's change to the stored collections

Vaultwarden 1.37.4 does not change an item's revision when its collections change (rig check
2026-10-30: `collections_v2` by the owner, `revisionDate` unchanged). So the conflict check of the
item PUT cannot see another member's collection change, and a sync while the sheet is open brings
it into the stored record. Saving the sheet's list as it is would undo it.
`DraftVaultItem.originalCollectionIds` keeps the item's collections when the sheet opened, and
`CollectionAssignment.rebased(stored:original:edited:)` applies only the user's change (ids added
and removed against that original) to the stored record's collections. The rebased list decides
whether the collections request is sent, what it carries (minus read-only ids, D2) and what Prizm
keeps locally. A new item has no original list and is saved as chosen.

### D3. Checkbox list

The "Collections" card lists the writable collections of the item's org, sorted by name, each as a
`Toggle` with `.toggleStyle(.checkbox)` labelled with the collection name. Read-only assignments
follow as disabled, checked rows with the secondary text "View only, can't be removed". Padding and
fonts use `Spacing.rowVertical`, `Spacing.rowHorizontal`, `Typography.fieldValue` and
`Typography.fieldLabel`. VoiceOver reads "<name>, checkbox, checked" for each, and the read-only
rows add the hint "View only. You can't remove this item from this collection." (§VIII).

If the org has no writable collection for the user, the card shows "You can't add items to any
collection in this organization." On create, Save stays disabled. On edit, an item that is in a
read-only collection can still be saved (its collection list is not empty).

The card sits in the sheet's fixed header, above the scrolling form. So that an org with many
collections cannot push the form out of the sheet, the rows scroll inside the card once they pass
a maximum height (a new `DesignSystem` token, about five rows). The sheet's overall height for org
items is a separate fix (batch item "edit sheet too short for an org item").

The create sheet pre-fills the sidebar collection only when the user can write it; a read-only one
is not pre-filled (the server would refuse the create).

### D4. Required collection

`ItemEditViewModel.canSave` is false for an org item whose final list (D2) is empty. A short
inline hint under the card says "Choose at least one collection." It is shown as soon as the list is
empty, like the name validation, in secondary text (not as an error). The create sheet keeps
pre-filling the sidebar collection (D3).

**Rejected alternative:** allow an empty list for admins, as the official server does. Prizm has no
admin view of unassigned items, so such an item would vanish from Prizm too.

### D5. Collections call only on change, with `collections_v2`

`update()` keeps today's order (cipher PUT first), as the web form does.
- The original set is the `collectionIds` of the stored server record the save is built on (the
  record `fix-cipher-edit-data-loss` keeps per item). It is what the server holds, so it is also
  right after a partly failed save and a retry, where the sheet's own snapshot moved on.
- If `Set(draft.collectionIds) == Set(record.collectionIds)`, no collections call is sent. The PUT
  answer is then the item's record, as for a personal item.
- Otherwise it calls `PUT /api/ciphers/{id}/collections_v2` with the D2a list minus read-only ids (D2) and decodes
  `{unavailable, cipher?}`.
  - `unavailable: true` → the item is removed from the local cache and the record store, and
    `update()` throws `VaultError.savedButAccessLost`. The edit sheet shows "Saved. You no longer
    have access to this item." with a Close button and Save disabled, as for an item that is gone
    after a conflict (§V: logged at `.info`).
  - `cipher` present → it becomes the stored record and patches `collectionIds` and `revisionDate`
    of the local item (as today's `/collections` answer does); no cipher → the record is fetched.
  - Error → kept as today: the local item gets the fields from the cipher PUT response with the
    *original* collections, and `update()` throws `VaultError.collectionChangeNotSaved` ("Your
    changes were saved, but the collection change failed. Try again."). The edit sheet stays open
    with the user's selection, so a retry is one click.

**Rejected alternative:** pass the original set from the edit sheet (`ItemEditViewModel.original`).
After a partly failed save the sheet's snapshot is the saved item, whose collections are the old
ones anyway; the stored record is the same set without a second source of truth.

**Rejected alternative:** keep the legacy `/collections` endpoint as the default. It still works on
both servers, but the SDK has moved to `collections_v2`, which also tells Prizm when the user lost
access.

### D5a. Legacy adapter for servers without `collections_v2`

Official servers before v2024.6.0 have no `collections_v2` (Context), and Prizm's collection
changes work there today. To keep them working, `LegacyCipherCollectionsEndpoint` (Data layer, its
own file) sends the old `PUT /api/ciphers/{id}/collections` with the same list. It maps the
`CipherDetailsResponseModel` reply to the same result as `collections_v2`, with
`unavailable: false`.

- It is reached only as a fallback: `collections_v2` answers 405, or 404 with an empty body (route
  missing). A 404 with an error body is a real "not found or not allowed" and is **not** retried,
  so the fallback never bypasses the server's hidden-password check on newer servers.
- The marker: `// LEGACY(Bitwarden server < v2024.6.0): remove when those versions are no longer
  supported`.
- Vaultwarden 1.32.0 and later never reach it.

### D6. Comment fix

`PrizmAPIClient.swift:95-98` is rewritten: the endpoint replaces the user's *writable* assignments
with the posted list; an empty list unassigns; the list carries only writable collections,
because Vaultwarden refuses any read-only id in it (rig result in Context). It links to
`CollectionCipher_UpdateCollections.sql` and `ciphers.rs`.

## Risks / Trade-offs

- **[Medium] Two requests are not atomic.** The cipher PUT can succeed and the collections call
  fail. → D5 keeps the local cache truthful and tells the user. The official clients have the same
  two-step flow.
- **[Low] Route-missing detection.** A proxy that turns every 404 into an HTML page would hide the
  difference between "route missing" and "not found". → Only an empty 404 body or 405 triggers the
  fallback; anything else is the D5 error path, which shows a message and changes nothing locally.
- **[Low] Hidden-password items** get 404 from `collections_v2` on the official server. → D5 error
  path; `honour-org-item-permissions` disables the picker in that case, as the web form does.
- **[Low] Stale collection list.** A collection created or re-permissioned on another device after
  the last sync is missing or wrongly flagged. A collection that became read-only is refused by the
  server and Prizm shows the error. A collection that was read-only at the last sync and has since
  become writable is left out of the request, and the server removes the item from it without an
  error. → Accepted: it needs a permission change between the last sync and the save; a sync
  before editing avoids it. The official clients send their cached list the same way.

## Open Questions

1. Answered by task 1.1 (Context, rig result): posting an unchanged read-only assignment back is
   refused on Vaultwarden 1.37.4, so Prizm leaves read-only ids out of the request (D2).
2. Should the favorite star and move-to-folder be disabled for items whose collections are all
   read-only? Out of scope here; `fix-favorite-and-folder-partial-updates` makes both work via
   `/partial` for such items.
