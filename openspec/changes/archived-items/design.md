# Design

## Context

### Servers

**Vaultwarden 1.37.4**
- `archivedDate` is per user:
  - sent in the user sync from the user's archive rows (`vaultwarden/src/db/models/cipher.rs:377-381`)
  - `null` when the item is not archived
- Endpoints:
  - `PUT /api/ciphers/<id>/archive`, `PUT /api/ciphers/archive`
  - `PUT /api/ciphers/<id>/unarchive`, `PUT /api/ciphers/unarchive`
  - routes at `src/api/core/ciphers.rs:1778-1805`
  - single archive at `:2026-2056`: it checks only that the item is accessible to the user, with
    no premium check
  - the response is the full cipher JSON (Vaultwarden only; the official answer model is not
    verified yet: task 1.1, so D3 takes nothing else from it)
- `PUT /api/ciphers/<id>` with `archivedDate` absent or null **unarchives** the item (`:580-586`).
- `/api/config` enables `pm-19148-innovation-archive` (`src/api/core/mod.rs:222`).
- The profile always reports `"premium": true` (`src/db/models/user.rs:312`).
- 1.37.3 has the same endpoints (`vaultwarden-1.37.3/src/api/core/ciphers.rs:99-102`).
- The endpoints and the sync `archivedDate` first appear in 1.36.0
  (`git show 1.36.0:src/api/core/ciphers.rs`, `:1738-1765`; `1.36.0:src/db/models/cipher.rs:383-386`).
  1.35.4 has neither. (An earlier plan review said 1.36.0 does not support archive; the 1.36.0
  source shows it does.)

**Official server** (source checked 2026-10-23; archive endpoints from v2025.10.0, absent in v2025.9.0)
- Endpoints `PUT /ciphers/{id}/archive`, `PUT /ciphers/archive`, `PUT /ciphers/{id}/unarchive` and
  `PUT /ciphers/unarchive` (`server/src/Api/Vault/Controllers/CiphersController.cs:1077,1094,1277,1294`).
- `ArchiveCiphersCommand` has no premium or feature check. It archives the user's matching
  ciphers that are not yet archived (`server/src/Core/Vault/Commands/ArchiveCiphersCommand.cs:23-60`).
- `CipherResponseModel.ArchivedDate` (`CipherResponseModel.cs:298,314`).
- The request writes `ArchivedDate` into the per-user `Archives` JSON
  (`CipherRequestModel.cs:79,195,257`). Whether an absent value removes the user's entry needs
  confirming (task 1.1).
- The profile has `Premium` and `PremiumFromOrganization`
  (`server/src/Api/Models/Response/ProfileResponseModel.cs:64-65`).

### Official clients

- **List filter.**
  - Archived items are hidden unless the Archive filter (or Trash) is selected
    (`clients/libs/vault/src/models/filter-function.ts:51-60`).
  - The Archive list shows archived, non-deleted items
    (`clients/libs/common/src/vault/services/default-cipher-archive.service.ts:27-37`).
  - iOS: `isActive = archivedDate == nil && deletedDate == nil`
    (`ios/BitwardenShared/Core/Vault/Extensions/CipherListView+Extensions.swift:37,42`).
- **AutoFill.** Archived items are excluded from autofill matching
  (`clients/libs/common/src/vault/services/cipher.service.ts:510-512`).
- **Gating.** The clients have no feature-flag check left for archive.
  - `userCanArchive$` is "has premium from any source"
    (`default-cipher-archive.service.ts:39-47`).
  - The Archive action is premium-gated; Unarchive is not
    (`clients/libs/vault/src/services/cipher-row-menu.service.ts:121-133,220-226`).
  - For an archived item when the user has no premium, the clients hide favourite, attachments and
    clone (`:169-197`).
  - Edit stays available (`:179-181`).
  - The audit's premium note ("Archive is gated by premium, not by `pm-19148`") holds for the
    clients. The servers do not enforce premium.

### Prizm today

- `RawCipher.archivedDate` is kept as opaque `JSONValue?` and written back on edit
  (`fix-cipher-edit-data-loss`), but never read into the Domain.
- `VaultItem` has no archive state (`Domain/Entities/VaultItem.swift:5-27`).
- `VaultRepositoryImpl.buildIndexes` treats every non-deleted item as active
  (`Data/Repositories/VaultRepositoryImpl.swift:111-158`).
- `SidebarSelection` has no archive case (`Domain/Entities/SidebarSelection.swift:47-52`).
- `RawProfile` doesn't decode `premium`; this change does not need it (D4).

## Goals / Non-Goals

**Goals**
- Prizm shows the same set of items in its everyday lists as the official clients do.
- Users can archive and unarchive in Prizm.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Decode `archivedDate` as an optional date

- `RawCipher.archivedDate` (a `JSONValue?` since `fix-cipher-edit-data-loss`, which keeps it on
  edit) is read as a date string into `VaultItem.archivedDate: Date?`, parsed with the same date
  parser as the other dates (see `fix-sync-decoding-resilience` D7).
- An unparseable non-null value counts as archived. The value is present, so the server considers
  the item archived; the parse failure is logged.

### D2. One "active" predicate for all everyday lists

`VaultItem.isActive = !isDeleted && archivedDate == nil`, as in iOS. `buildIndexes` uses it for
All Items, Favorites, types, folders, collections, organizations and Codes. New selections:
- `.archive`: `!isDeleted && archivedDate != nil`
- `.trash`: unchanged, `isDeleted` regardless of archive state

Search inside the list uses the current selection, as today, so archived items are found only
inside the Archive view. Global search always searches the `.allItems` scope
(`VaultBrowserViewModel.swift:345-347`), so it does not find archived items either.

**Lookups by id.** `allItems()` returns the All Items index, which loses archived items. Callers
that look up one item by id must see every non-deleted item:
`AttachmentRepositoryImpl.swift:139,324` (legacy attachment-list patch: an empty list would erase
an archived item's attachments locally), `VaultBrowserViewModel.swift:370` (detail refresh) and
`:438` (attachment-conversion notice). The first three use the existing
`VaultRepository.itemDetail(id:)`, which looks over every cached item; the notice reads
`allItems()` plus `items(for: .archive)`.

**Every `VaultItem` builder carries `archivedDate`:** `DraftVaultItem → VaultItem`
(`DraftVaultItem.swift:421-425`) and every `with(...)` (`VaultItem.swift:124-160`); otherwise a
local edit or move puts an archived item back into All Items until the next sync.

**Delete and restore** keep the cached `archivedDate` only when the server answer or re-fetched
record says so: after soft delete and restore, the cached `archivedDate` is taken from the record
that the existing refresh fetches (task 1.1 records whether either server clears it).

### D3. Archive and Unarchive call the dedicated endpoints

- `PrizmAPIClient.archiveCipher(id:)` and `unarchiveCipher(id:)` → `PUT /api/ciphers/{id}/archive`
  and `/unarchive`; no body.
- `VaultRepository.setArchived(id:archived:)` runs the request inside `serialised([id])` with the
  store generation token, like `performRestoreItem` (`VaultRepositoryImpl.swift:832-850`); a lock
  during the request drops the result. One use case, `SetItemArchivedUseCase.execute(id:archived:)`
  (Domain protocol, Data impl), calls it; it never touches repository state itself.
- The answer is not applied (the official answer may be a `CipherMiniResponseModel` without
  folder, favourite, edit or collections; task 1.1). After the request, the cached item moves to
  Archive or back at once, from what was asked, and the record is fetched (`refreshRecord`), which
  updates the stored record, so the next edit sends the current `archivedDate` back.
  Changed after the review (2026-10-31): the first version patched the stored record with the
  answer's `archivedDate` and `revisionDate`. When another client had changed the item before the
  archive, that record held the old content with the new revision, and the next save overwrote the
  other client's change without a conflict. `refreshRecord` compares the fetched record with the
  one the cached item came from and keeps the cached revision behind when they differ, so the
  conflict check stays. Cost: one `GET /api/ciphers/{id}` per archive action.
- `archivedDate` joins `RecordContent.ignoredMembers` (`VaultRepositoryImpl.swift:1520-1523`): an
  archive change is one of Prizm's own operations, so a refresh must not read it as "changed
  elsewhere" and keep a stale revision (every later edit would then fail with `conflict`). The
  refresh after delete, restore, favourite, move and collection update also copies `archivedDate`
  from the fresh record to the cached item, so an archive change made elsewhere reaches the lists;
  it does so also when the refresh finds the item changed elsewhere and keeps the cached revision,
  since the archive state is per user and not part of the conflict check (verify 2026-10-31).
- If the record fetch after the request fails, the stored record keeps its old `archivedDate` until
  the next sync. A later edit would send that state back; if the archive request bumped the
  revision, that edit meets the conflict check first. Accepted: the window is one failed `GET`.
- `setCipherArchived` still decodes the answer (`ArchiveStateAnswer`), only for the client test
  that tells `null` from an absent value (task 4.1); the repository ignores it.
- Item fields are never re-sent, so these actions can't lose data.

**Rejected alternative:** set `archivedDate` through a full `PUT`. That rewrites the whole item
(the data-loss path) and depends on the server honouring a client-supplied date.

### D4. No premium gate

Decided with Christian (2026-10-30): Prizm gates a feature only where the server enforces it. No
server does for archive: the official `ArchiveCiphersCommand` has no premium or feature check, and
Vaultwarden has none either (Context). So Archive and Unarchive are always offered, whatever the
profile's `premium` value, also on read-only organization items and items with an edit block
(archive is per user), and favourite and attachment actions stay on archived items. If a server refuses the request, Prizm shows the
server's message (`server-error-texts`) and the item stays where it is.

**Rejected alternative:** the official clients' client-side premium gate (`userCanArchive$`,
`cipher-row-menu.service.ts:169-197`). It enforces nothing on the server and would only copy
another client's licensing decision.

### D5. Servers without archive: a legacy-tolerant path

Vaultwarden < 1.36.0 and Bitwarden servers < v2025.10.0 have no archive. Prizm has no archive
feature today, so nothing that works there now can break. The point of D5 is that those servers
keep looking exactly as they do today:
- No `archivedDate` key → `nil` → every item stays active (D2). Lists are unchanged.
- Detection: `VaultRepository.isArchiveSupported()` reads the stored records (`RawCipherStore`):
  true when any record has the `archivedDate` key, or when there is none. Sync, create and save
  answers all update the stored records, so each of them re-checks it; the browser reads it with
  the sidebar counts. While it is false, Archive is hidden (Unarchive stays for an archived item).
- The Archive sidebar entry needs no rule of its own: it is shown only when its count is above 0,
  which on these servers never happens.
- A 404 **without** a server error message from the archive endpoint shows "This server doesn't
  support archiving items." A 404 with a message (item gone or not accessible) shows that message
  (`server-error-texts`). In both cases the item stays where it is.

The detection and the 404 mapping exist only for these older servers. They live in one small
Data-layer type, `LegacyArchiveSupport` (`Prizm/Data/Repositories/Legacy/LegacyArchiveSupport.swift`),
marked `// LEGACY(Vaultwarden < 1.36.0, Bitwarden server < v2025.10.0): remove when those versions are no longer supported`.
It is consulted only when the key is absent or the endpoint answers 404; on a server with archive
it changes nothing. The UI-test vault's seeded records carry `archivedDate` (`null`, or a date for
the archived login that `--ui-test-archived` adds), as a server with archive sends them.

### D6. Presentation

- The sidebar "Archive" entry sits in the `.trash` section, before Trash (`SidebarView.swift:139-141,204`),
  using SF Symbol `archivebox`, shown only while its count is above 0.
- If the entry disappears while selected (the last archived item was unarchived or deleted), the
  selection falls back to All Items, as for a deleted folder or collection
  (`VaultBrowserViewModel.swift:819,917`). An item that leaves the current list after an action
  stays selected in its new list.
- `SidebarSelection.archive` is added to `displayName`, the hand-written `==` (which ends in
  `default: return false`, so a missing case compiles) and `hash` (value 10).
- The detail header shows an "Archived" badge.
- Context menu and toolbar offer "Archive" / "Unarchive".
- VoiceOver:
  - the badge is read as "Archived"
  - after an action, "Item archived" or "Item unarchived" is announced
- Spacing and fonts come from `DesignSystem.swift`.

## Risks / Trade-offs

- **[Medium] Editing archived items.** `fix-cipher-edit-data-loss` (merged) sends `archivedDate`
  back as received, so an edit keeps the item archived; D3 refreshes the stored record after each
  archive action so that value is current.
- **[Low] Users without premium on Bitwarden's own servers can archive in Prizm** although the
  official clients do not offer it to them. The server accepts it (D4); accepted.
- **[Low] Older servers.** D5 keeps them as they are today; the legacy type is listed in
  `FIX-ORDER.md`, "Legacy adapters".

## Open Questions

1. Does the official server's `PUT /ciphers/{id}` clear the user's archive entry when
   `archivedDate` is absent, as Vaultwarden does? Task 1.1 (from source). Prizm always sends it
   back, so it affects no code here.

Closed 2026-10-30 (Christian): no premium gate (D4).
