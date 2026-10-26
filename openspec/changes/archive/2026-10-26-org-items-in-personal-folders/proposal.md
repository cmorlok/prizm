# Proposal

## Why

**Criticality:** P3 (Low: parity)
**Findings:** CF-07 (`06-client-features.md`)

In Bitwarden, folders are personal, but they are not limited to personal items. Each user can file
any item they can see, including organization items, into their own folders. The folder choice is
stored per user, so it doesn't affect other members. Both servers send each user's folder for org
items in the sync, and the official clients show org items in the folder the user chose.

Prizm reads that folder ID but ignores it for org items. The folder lists contain only items with
`organizationId == nil` (`Prizm/Data/Repositories/VaultRepositoryImpl.swift:133-137`). A user who
filed org items into "Work" in the browser extension finds "Work" empty or incomplete in Prizm.
The edit sheet also offers no folder picker for org items (`Presentation/Vault/Edit/ItemEditView.swift:66-104`).

**Origin of the current behaviour:** wrong premise. The spec says:

> Org items SHALL be excluded from folder selections (personal folders are not org collections).
> — `openspec/specs/org-vault-items/spec.md:19` (from `923fa5b`, 2026-04-19, kept in `3bd1f19`)

The parenthesis is true, but it doesn't lead to the rule. Folders and collections are independent:
an org item has collections (shared) and, per user, a folder (private).

A related local bug surfaces as soon as org items appear in folders. `moveItemToFolder`,
`moveItemsToFolder` and `deleteFolder` rebuild the moved `VaultItem` without `organizationId` and
`collectionIds` (`VaultRepositoryImpl.swift:452-458`, `:517-521`, `:530-535`). The org item then
looks personal in Prizm until the next sync, and an edit in that window fails with "Organization
mismatch". `fix-favorite-and-folder-partial-updates` fixes all three paths. This change depends on
it.

## What Changes

- **Folder lists and counts include org items** whose per-user `folderId` matches. This is the same
  filter as the official clients.
- **The edit sheet shows the folder picker for org items too,** next to the collection picker, as
  in the official item form.
- **Drag and drop** of org items onto a folder is supported. It uses the existing per-user move
  endpoints, which work for org items on both servers.
- **The wrong spec rule is replaced** when this change is archived.

## Capabilities

### New Capabilities
- `org-items-in-folders`: organization items can be filed in, and are listed under, the user's
  personal folders.

### Modified Capabilities
- `org-vault-items`: "Org items appear in All Items and in their collection sidebar selection" no
  longer excludes org items from folders (MODIFIED).
- `vault-item-create`: "Edit and create sheets include a folder picker" shows the picker for org
  items too (MODIFIED).
Both main specs were first given the `## Purpose` / `## Requirements` structure by
`fix/000-openspec-main-spec-repair`, so they can take MODIFIED deltas.

## Non-Goals

- Changing collections. The collection picker's own problems (audit W-02) are a separate change.
- A "No folder" view.
- Moving items between personal vault and organization.

## Dependencies

- **Hard:** `fix-favorite-and-folder-partial-updates`. Moving an org item to a folder, or deleting
  a folder that holds one, must keep its organization and collections. Without that fix, the new
  drag and drop and folder picker would make more org items look personal, and their next edit
  would fail. `fix-cipher-edit-data-loss` lists the same fix as INTEG-01; whichever lands first
  satisfies this dependency.
- **Soft:** `fix-sync-decoding-resilience`. Placeholder items follow the same folder rule.

## Impact

- **Data:**
  - `VaultRepositoryImpl.buildIndexes` folder filter
  - `update()` sends `folderId` for org items (already in `toRawCipher`, `CipherMapper.swift:364`)
- **Domain:** none.
- **Presentation:**
  - `ItemEditView` shows the folder picker for org items as well
  - drag and drop accepts org items
  - VoiceOver labels unchanged
  - DesignSystem tokens only
- **Specs:** the folder rules in `org-vault-items` and `vault-item-create` are replaced (MODIFIED deltas).
- **No new dependencies.**
- **Security review:** no. No crypto, keys or secrets touched; folder IDs are plaintext per-user
  metadata.

## Estimate

Ideal engineer-days, TDD included, assuming `fix-favorite-and-folder-partial-updates` has landed.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Verify per-user folder handling on both servers | 0.25 d |
| 2 | Folder index and counts | 0.25 d |
| 3 | Folder picker for org items; drag and drop | 0.5 d |
| 4 | Spec repair and rule change, CHANGELOG | 0.25 d |
| **Total** | | **1.25 d** |
