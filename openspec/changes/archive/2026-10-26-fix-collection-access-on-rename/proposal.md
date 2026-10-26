# Proposal

## Why

**Criticality:** P0 (Critical: destroys data now)
**Findings:** W-01, W-10 (`04-write-paths.md`)

**Renaming a collection removes everyone's access to it.** `renameCollection` sends
`PUT /api/organizations/{org}/collections/{id}` with `{name, groups: [], users: []}` and no
`externalId` (`Prizm/Data/Network/PrizmAPIClient.swift:917-947`). Both servers read the lists as
"replace the access list with this":

- Vaultwarden 1.37.4 deletes every group and member assignment of the collection, then adds the
  posted ones (none), and sets `external_id` to `None`.
- The official server replaces the assignments the same way and overwrites `ExternalId`. If the
  organization does not give admins access to all collection items, it rejects the request instead
  ("At least one member or group must have can manage permission").

After a rename, members and groups that are not owners or admins lose access to the collection and
its items. Directory or SCIM sync loses its link to the collection (`externalId`). This needs no
other bug to happen; it works the same on both servers today.

**A new collection has no manager.** `createCollection` sends `users: []` and `groups: []`
(`PrizmAPIClient.swift:924-935`). The web vault preselects the creator with **Manage**. On the
official server a collection without a Manage holder is rejected, unless admins may access all
collection items. Where it is accepted, the creator is not assigned and the collection can drop out
of the creator's own `/sync` after the next sync.

### Origin of the current behaviour

**Accidental.** The comment on the body type says only "`groups` and `users` default to empty"
(`PrizmAPIClient.swift:917`). The org-support design lists "Collection access control per user
(accept whatever the server returns)" and "groups feature" as non-goals
(`openspec/changes/archive/2026-04-19-org-support/design.md:20-22`). Nothing shows awareness that
an empty list overwrites access. Introduced in commit `923fa5b` (PR #41).

## What Changes

Rename stays a full feature. This change repairs it; it is not removed or restricted.

- **Rename keeps access.** Before renaming, Prizm reads the collection's current access with
  `GET /api/organizations/{org}/collections/{id}/details` and sends the same `users`, `groups` and
  `externalId` back with the new name, the way the web vault does.
- **Create assigns the creator as manager.** A new collection is created with the current member
  in `users` with `manage: true`, `readOnly: false`, `hidePasswords: false`, like the web dialog's
  default.
- **Fail closed.** If the access list cannot be read, the rename is not sent and the user sees an
  error. Prizm never sends empty lists for a rename.
- **Works on every server where rename works today.** The details endpoint exists in Vaultwarden
  1.32.0 to 1.37.4 and in the official server (design.md, Context, "Older servers"). No server
  detection is needed.
- **Create on official servers before v2025.1.0**, which do not send `organizationUserId`, keeps
  today's request through a separate legacy adapter (`LegacyCollectionCreateWithoutMembership`,
  design.md D3), so create keeps working there.
- The misleading comment on the request body is replaced.

## Capabilities

### New Capabilities
- `collection-access-preservation`: collection rename and create never remove or omit access
  assignments.

### Modified Capabilities
_None in this change._ `openspec/specs/org-collections/spec.md:102-125` ("User can rename a
collection") names the endpoint but not the body. At archive time, add a sentence there that the
rename resends the current access list.

## Non-Goals

- Editing collection access (members, groups, permissions) in Prizm. Prizm keeps what is there.
- Nested collections, collection-level permission checks (`manage`, `limitCollectionCreation`).
  Who may rename or create is audit finding W-09 and belongs to `honour-org-item-permissions`.
- Admin-console endpoints (`/collections/bulk-access`, provider access).
- Repairing collections that already lost their access. Prizm cannot know what was there. The
  CHANGELOG tells admins to check collections renamed with Prizm.

## Dependencies

- None hard.
- Soft: `honour-org-item-permissions` (W-09: custom-role and `manage` permissions). It decides who sees Rename and
  Create; this change decides what they send.

## Impact

- **Data:**
  - `PrizmAPIClient`: new `getCollectionAccessDetails(organizationId:id:)`; new request and
    response types for access selections; `renameCollection` and `createCollection` take them.
  - `SyncResponse.swift` `RawOrganization`: decode `organizationUserId`.
  - `VaultRepositoryImpl.renameCollection` / `createCollection`: read, then write.
  - New `Data/Repositories/Legacy/LegacyCollectionCreateWithoutMembership.swift`.
- **Domain:** `Organization` gains `membershipId: OrgMembershipId` (the org-user id, not a secret), with the states `.known(id)`, `.notSent` and `.unreadable` (design D3).
- **Presentation:** none, apart from the existing error path for rename and create.
- **No new dependencies.**
- **Security review: yes.** No crypto change, but the change touches access control on shared
  data (§III, vault-touching code path).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm details response and permissions on both servers | 0.25–0.5 d |
| 2 | Access-details API call and models | 0.5 d |
| 3 | Rename resends access and `externalId` | 0.5 d |
| 4 | Create assigns the creator with Manage; legacy create adapter | 0.5–0.75 d |
| 5 | Live check on both servers, security review, CHANGELOG | 0.5 d |
| **Total** | | **2.25–2.75 d** |
