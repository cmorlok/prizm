# Design

## Context

Sources: `$SRC` checkouts of 2026-10-23 (clients, server) and Vaultwarden tag 1.37.4.

**Official server.**
- `PUT /organizations/{orgId}/collections/{id}` passes `model.Groups` and `model.Users` to
  `UpdateCollectionCommand` (`server/src/Api/AdminConsole/Controllers/CollectionsController.cs:220-248`).
- `null` means "don't change that association"; a list, even an empty one, replaces it
  (`server/src/Core/AdminConsole/OrganizationFeatures/Collections/UpdateCollectionCommand.cs:62-87`;
  `server/src/Infrastructure.Dapper/AdminConsole/Repositories/CollectionRepository.cs:296-325`).
- Without `AllowAdminAccessToAllCollectionItems`, the update needs at least one group or user with
  Manage, or it fails with "At least one member or group must have can manage permission"
  (`UpdateCollectionCommand.cs:65-84`).
- `ExternalId` is always taken from the body (`server/src/Api/AdminConsole/Models/Request/CollectionRequestModel.cs:55-68`).
- Create applies the same Manage rule, without the "null keeps existing" escape
  (`CreateCollectionCommand.cs:63-70`). A missing `users` list becomes an empty list
  (`CollectionsController.cs:197-198`).
- `GET /organizations/{orgId}/collections/{id}/details` returns the collection with `users`,
  `groups` and `externalId` (`CollectionsController.cs:73-91`, `CollectionResponseModel.cs:68-116`).
  Each selection is `{id, readOnly, hidePasswords, manage}`; `id` is the organization-user id.
- Everyone allowed to update a collection may also read it with access: `ReadWithAccess` allows
  owners, admins, `EditAnyCollection`, `DeleteAnyCollection`, `ManageUsers`, members with Manage on
  the collection, and providers; `Update` allows a subset of these
  (`server/src/Api/AdminConsole/Authorization/Collections/BulkCollectionAuthorizationHandler.cs:154-210`).
- The sync profile carries `organizationUserId` for every organization
  (`server/src/Api/AdminConsole/Models/Response/ProfileOrganizationResponseModel.cs:22,41`) and the
  flag `allowAdminAccessToAllCollectionItems` (`BaseProfileOrganizationResponseModel.cs:71,124`).

**Vaultwarden 1.37.4.**
- The body type `FullCollectionData` has `groups: Vec<…>` and `users: Vec<…>`, not optional
  (`vaultwarden/src/api/core/organizations.rs:118-125`). Sending `null` is a decode error, so the
  official server's "null keeps access" shortcut does not work here.
- `put_organization_collection_update` sets `external_id` from the body (empty or missing → `None`),
  deletes all `CollectionGroup` and `CollectionUser` rows, then saves the posted ones. Members with
  `access_all` are skipped (`organizations.rs:604-670`).
- `get_org_collection_detail` (`organizations.rs:734-790`) returns `users`, `groups` (empty when org
  groups are disabled) and `externalId` (`src/db/models/collection.rs:69-71`). It needs at least
  Manager rights on that collection (`ManagerHeaders`, `src/auth.rs:886-889`), the same guard as the
  PUT.
- In the details response, a member's `manage` is derived: true for admins and owners, and for
  managers with full read/write (`collection.rs:971-981`).
- Create does not check for a Manage holder. Managers without `access_all` cannot create at all
  (`organizations.rs:465-480`). The profile sends `organizationUserId`
  (`src/db/models/organization.rs:500`) and always `allowAdminAccessToAllCollectionItems: true`
  (`organization.rs:517`).

**Older servers.**
- `GET /organizations/{org}/collections/{id}/details` with `users` and `groups` exists in every
  supported version: Vaultwarden 1.32.0 (`git show 1.32.0:src/api/core/organizations.rs`, `:639`,
  route parameter `<coll_id>`) to 1.37.4; official v2024.1.0 (`src/Api/Controllers/CollectionsController.cs:79`),
  v2024.6.0 (`:75`) to v2025.12.0, later moved to `src/Api/AdminConsole/Controllers/`.
- Vaultwarden 1.32.0 already requires both lists on PUT (`NewCollectionData { groups: Vec, users: Vec,
  external_id: Option }`, `organizations.rs:126-131` at 1.32.0) and replaces them, like 1.37.4.
- `organizationUserId` in the sync profile: Vaultwarden 1.32.0 sends it
  (`1.32.0:src/db/models/organization.rs:396`). The official server sends it from v2025.1.0
  (`ProfileOrganizationResponseModel.cs:55,114`); v2024.1.0 and v2024.6.0 send only `UserId`.
- So read-and-resend works on every server where rename works today. Only create needs a legacy
  path, for official servers before v2025.1.0 (D3).

**Web vault.**
- The collection dialog loads collections with access through
  `GET /organizations/{orgId}/collections/details` (`clients/libs/common/src/services/api.service.ts:475-486`,
  via `collectionAdminViews$`, `clients/libs/admin-console/src/common/collections/services/default-collection-admin.service.ts:39-55`;
  dialog `collection-dialog.component.ts:179-202`).
- On save it sends back every user and group with their flags, plus `externalId`
  (`default-collection-admin.service.ts:181-214`).
- For a new collection it preselects the current member (looked up by `organization.userId`) with
  `CollectionPermission.Manage` (`apps/web/src/app/admin-console/organizations/shared/components/collection-dialog/collection-dialog.component.ts:393-425`).
- The client also has a per-collection call, `getCollectionAccessDetails` →
  `GET /organizations/{orgId}/collections/{id}/details` (`api.service.ts:445-456`).

**Prizm today.**
- `CollectionBody {name, groups: [String], users: [String]}` with empty arrays on create and rename
  (`Prizm/Data/Network/PrizmAPIClient.swift:917-947`). No `externalId`.
- `VaultRepositoryImpl.renameCollection` and `createCollection` (`Prizm/Data/Repositories/VaultRepositoryImpl.swift:471-498`)
  call it directly.
- `RawCollection` decodes only `id`, `organizationId`, `name` (`Prizm/Data/Network/Models/SyncResponse.swift:112-135`).
  `RawOrganization` decodes `id`, `name`, `key`, `type` (`SyncResponse.swift:73-102`).

## Goals / Non-Goals

**Goals**
- A rename changes the name and nothing else, on both servers.
- A collection created in Prizm is managed by its creator, as in the web vault.
- No request ever carries an access list Prizm did not read from the server.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Read the access list, then resend it

`renameCollection` first calls `GET /api/organizations/{org}/collections/{id}/details`. It then
sends `PUT` with `name` (new, encrypted with the org key), `externalId`, `users` and `groups` exactly
as read, including each `readOnly`, `hidePasswords` and `manage` flag.

The per-collection endpoint is used rather than the web vault's org-wide `/collections/details`:
it returns the same shape for one collection and exists on both servers, in every supported version
(Context, "Older servers"). The same path is used for every server; no server detection.

Rename stays a full feature. This change repairs it; it does not remove or restrict it.

**Rejected alternative:** send `users: null, groups: null`. The official server treats null as
"don't change" (`UpdateCollectionCommand.cs:63`), but Vaultwarden 1.32.0–1.37.4 cannot decode
`null` there (`Vec`, not `Option`), so the rename would fail. Using it only on the official server
would need reliable server detection, which Prizm does not have. Read-and-resend works on both and
matches the web vault.

**Rejected alternative:** disable rename until a later fix. Rename is a basic action and the fix is
small.

### D2. Fail closed

If the details call fails, or its response lacks `users` or `groups`, the rename is not sent. There
is no fallback that sends empty or invented lists. The
user sees "Couldn't rename the collection. Its access settings could not be read." and the name
reverts (existing error path, `org-collections` spec "Server error during collection rename").
The error is logged with the HTTP status, never with names.

### D3. Create with the creator as manager

`createCollection` sends `users: [{id: membershipId, readOnly: false, hidePasswords: false,
manage: true}]`, `groups: []`, `externalId: null`. `membershipId` is the profile's
`organizationUserId`, decoded in `RawOrganization` and carried on the Domain `Organization`.

Vaultwarden 1.32.0+ and official v2025.1.0+ always send `organizationUserId` (Context). If the
field is present but can't be decoded, the create is not sent and the user sees the existing
create error. Prizm never guesses an id.

**Legacy: profile without `organizationUserId`.** Official servers before v2025.1.0 do not send the
field. Creating a collection works there today (with `users: []`, accepted when admins may access
all collection items). To keep that, a separate adapter `LegacyCollectionCreateWithoutMembership`
(`Prizm/Data/Repositories/Legacy/LegacyCollectionCreateWithoutMembership.swift`) sends today's body
(`users: []`, `groups: []`, `externalId: null`) only when the profile has no `organizationUserId`
key at all. It is marked
`// LEGACY(Bitwarden server < v2025.1.0, no organizationUserId in the profile): remove when those versions are no longer supported`
and logs at `.info` that it was used. It is never used for rename, and never when the field is
present.

### D4. Types

Data-only Codable types: `CollectionAccessSelection {id, readOnly, hidePasswords, manage}`,
`CollectionAccessDetailsResponse {id, organizationId, name, externalId?, users, groups}` (both
key casings, like `RawCollection`) and `CollectionWriteRequest {name, externalId?, users, groups}`.
`externalId` is encoded as JSON `null` when absent. The old `CollectionBody` is removed.

### D5. No local access model

The access list is used only inside the repository call and dropped afterwards. It is not cached
and does not enter Domain.

## Risks / Trade-offs

- **[Medium] Lost update between read and write.** If another admin changes access between the
  GET and the PUT, Prizm writes the older list back. The web vault has the same window (it reads
  when the dialog opens). → The window is one round trip; documented here.
- **[Low] Vaultwarden derives `manage` in the details response** (`collection.rs:971-981`).
  Resending it can store `manage: true` for a manager who had full read/write but no explicit
  Manage flag. Effective rights don't change, because Vaultwarden already treats such a manager as
  able to manage. The web vault behaves the same.
- **[Low] Vaultwarden with groups disabled** returns `groups: []`. Resending deletes stale
  `CollectionGroup` rows from a time when groups were enabled. The web vault does the same.
- **[Low] Already damaged collections stay damaged.** → CHANGELOG note for admins.
- **[Low] A member who may rename but not read access details** would now get an error instead
  of a rename that wipes access. Both servers grant the details read to everyone allowed to update
  (Context), so this should not happen; if it does, failing is the safe result.

## Open Questions

1. Should the create request also add the creator when the org allows admin access to all items?
   The web vault always preselects; this design follows it.
