# Proposal

## Why

**Criticality:** P0 (Critical: destroys data now)
**Findings:** W-02, W-07, W-08 (`04-write-paths.md`)

**Saving an org item can remove it from its collections.** The collection picker in the edit sheet
is a single-choice menu with a "None" entry (`Prizm/Presentation/Vault/Edit/ItemEditView.swift:56-97`).
- An item in collections A and B loses B as soon as the user picks A (or anything else) and saves.
- "None" sends an empty list, which unassigns the item from every collection the user can write.
  Members who saw the item through those collections lose it, often including the editor.

**The picker offers collections the user can only read.** Both servers refuse to add an item to a
read-only collection. Vaultwarden fails the whole collections request; the official server ignores
the read-only part.

**A new org item can be created without a collection.** Choosing "None" in the create sheet sends
`POST /api/ciphers/create` with `collectionIds: []` (`ItemEditViewModel.swift:202-216`). On the
official server this creates an *unassigned* item that only admins can see; for a regular member
it disappears right after saving. Vaultwarden rejects it for non-admins.

**Every org save calls the collections endpoint.** `update()` always calls
`PUT /api/ciphers/{id}/collections` after the cipher PUT, even when nothing changed
(`Prizm/Data/Repositories/VaultRepositoryImpl.swift:529-551`). (The favorite star and moving to a
folder no longer do: since `fix-favorite-and-folder-partial-updates` they use `/partial`.) On
Vaultwarden the call fails for members whose collections are read-only ("Collection cannot be
changed"). The item is then saved but the user sees "Your changes were saved, but the collection
change failed." although they changed no collection.

On the official server every save also writes an extra `Cipher_UpdatedCollections` event to the
org's event log.

These paths reach the server only through the cipher PUT and POST. Those calls currently fail on
Vaultwarden 1.37.4 for a separate reason (missing `encryptedFor`, fixed by
`fix-cipher-edit-data-loss`). The data loss is real on the official server today, and on
Vaultwarden as soon as that fix ships.

### Origin of the current behaviour

- **Wrong premise.** `PrizmAPIClient.swift:95-98` says: "Passing an empty array moves the item to
  the org's Default collection." That is false. The official stored procedure removes the item from
  every writable collection that is not in the list
  (`server/src/Sql/dbo/Stored Procedures/CollectionCipher_UpdateCollections.sql`), and Vaultwarden
  does the same through a symmetric difference (`vaultwarden/src/api/core/ciphers.rs:841-873`).
- **Deliberate single choice.** The org-support spec asks for one "Collection" picker
  (`openspec/specs/vault-item-create/spec.md:31-46`, commit `923fa5b`).
- **Accidental:** read-only collections in the list, "None" on create, and the unconditional
  collections call. No reason is recorded.

## What Changes

- **Multi-select picker.** Org items get a list of checkboxes, one per collection the user can
  write. Existing assignments are pre-checked.
- **Read-only and unknown assignments are kept.** Collections the item is in but the user cannot
  change are shown as checked and disabled ("View only, can't be removed") and stay assigned.
  Read-only collections are left out of the collections request, which Vaultwarden refuses
  otherwise; assignments to collections Prizm does not know are sent back unchanged.
- **Other members' changes are kept.** A save applies the user's collection change to the
  collections the server holds now, so a change another member made while the sheet was open is
  not undone.
- **At least one collection.** Create and edit of an org item require at least one collection.
  Save stays disabled until one is checked. "None" is removed.
- **Collections call only on change.** `update()` calls the collections endpoint only when the set
  differs from the original. It uses `PUT /api/ciphers/{id}/collections_v2`, as the official SDK
  does, and reads the result (`unavailable`, `revisionDate`). Official servers before v2024.6.0
  have no `collections_v2`; there a legacy adapter falls back to today's
  `PUT /api/ciphers/{id}/collections` (design.md D5a), so nothing that works today stops working.
- **Clear error when the second call fails.** If the cipher was saved but the collection change
  failed, the user sees "Your changes were saved, but the collection change failed. Try again." and the local cache
  keeps the saved fields with the old collections.
- **Sync decodes collection permissions.** `readOnly`, `hidePasswords` and `manage` are decoded
  from `/sync` and `readOnly` is carried on `OrgCollection`.
- The false comment at `PrizmAPIClient.swift:95-98` is replaced.

## Capabilities

### New Capabilities
- `cipher-collection-assignment`: saving an org item changes only the collection assignments the
  user changed, never removes ones the user cannot change, and never leaves an org item without a
  collection.

### Modified Capabilities
- `vault-item-create` (edited at archive time, task 6.4): the org collection requirement describes the Collections card with
  checkboxes (details in `cipher-collection-assignment`) instead of a single "Collection" picker,
  and pre-fills only a writable collection on create.

## Non-Goals

- Moving an item between personal vault and organization ("share"), or between organizations.
- Admin endpoints (`collections-admin`) and unassigned items; Prizm has no admin console.
- Honouring "hide passwords" (`viewPassword`) and `edit` on items. That is audit finding W-06 /
  W-14 and belongs to `honour-org-item-permissions`. Until then, `collections_v2` can answer 404 for
  an item with hidden passwords; Prizm shows the error from D5.
- Default user collections ("My items", `type: 1`). Vaultwarden 1.37.4 does not support them;
  Prizm treats them like any other collection.

## Dependencies

- None hard.
- Soft: `fix-cipher-edit-data-loss`. After an org save its stale-write rule takes the stored
  record's revision from the answer to the collection update (its design D6, task 4.4); with this
  change that is the `collections_v2` response when one is sent.
- Soft: `fix-favorite-and-folder-partial-updates`. Once the favorite star uses `/partial`, it no
  longer triggers the collections call at all.
- Soft: `honour-org-item-permissions` (W-06 / W-14), which disables the picker when the user may not
  assign collections.

## Impact

- **Data:**
  - `SyncResponse.swift` `RawCollection`: decode `readOnly`, `hidePasswords`, `manage`.
  - `PrizmAPIClient`: `updateCipherCollections` → `collections_v2`, returns the optional cipher.
  - New `LegacyCipherCollectionsEndpoint` (fallback for Bitwarden server < v2024.6.0).
  - `VaultRepositoryImpl.update`: compare sets, call only on change, handle `unavailable`.
- **Domain:** `OrgCollection.readOnly: Bool`; a pure helper that builds the final collection list
  (writable selection + kept assignments); `VaultError.collectionChangeNotSaved` (exists since `fix-cipher-edit-data-loss`) and a new
  `VaultError.savedButAccessLost`.
- **Presentation:** `ItemEditView` collection section (checkbox list, VoiceOver labels,
  DesignSystem tokens); `ItemEditViewModel.canSave` requires a collection for org items.
- **No new dependencies.**
- **Security review: yes** (access control on shared items; §III vault-touching code).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm `collections_v2` and read-only behaviour on both servers | 0.25–0.5 d |
| 2 | Decode collection permissions; final-list helper | 0.5 d |
| 3 | Multi-select picker with accessibility | 1–1.5 d |
| 4 | Required collection on create and edit | 0.25 d |
| 5 | Collections call only on change, `collections_v2`, error path, legacy fallback | 1–1.25 d |
| 6 | Live check, security review, CHANGELOG | 0.5 d |
| **Total** | | **3.5–4.5 d** |
