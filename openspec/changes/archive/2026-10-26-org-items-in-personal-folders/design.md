# Design

## Context

### Folders are per user, including on org items

- **Vaultwarden 1.37.4.** In a user sync, `folderId` comes from the user's own folder mapping for
  every cipher, org or personal (`vaultwarden/src/db/models/cipher.rs:367-371`, inside `if sync_type
  == CipherSyncType::User`).
  - Bulk move (`PUT /api/ciphers/move`) moves every cipher the user can access
    (`src/api/core/ciphers.rs:1660-1664`, `find_by_user_and_ciphers` then `move_to_folder`).
- **Official server.** The `Folders` column is per-user JSON. `Cipher_Move` sets the user's entry
  for every cipher in `UserCipherDetails(@UserId)`, which includes org ciphers the user can access
  (`server/src/Sql/dbo/Vault/Stored Procedures/Cipher/Cipher_Move.sql`).
  - A full `PUT` writes `FolderId` for the user (`CipherRequestModel.cs:193`) and
    `UpdateUserSpecificJsonField(existingCipher.Folders, userIdKey, FolderId)` (`:255`).

### Official clients

- The folder filter is `cipher.folderId === this.folderId`, with no organization check
  (`clients/libs/vault/src/models/vault-filter.model.ts:133-142`).
- The item form shows the folder select for all items in the user's vault, below the collections
  select (`clients/libs/vault/src/cipher-form/components/item-details/item-details-section.component.html:51-77`).
  It is hidden only in the admin console (`hideIndividualVaultFields`).

### Prizm today

- Folder index: `active.filter { $0.organizationId == nil && $0.folderId == folder.id }`
  (`Prizm/Data/Repositories/VaultRepositoryImpl.swift:133-137`). Counts derive from it (`:171-173`).
- `CipherMapper.map` already reads `folderId` for org items (`CipherMapper.swift:151`).
  `toRawCipher` already sends it (`:364`).
- Edit sheet: the collection picker for org items, otherwise the folder picker
  (`Presentation/Vault/Edit/ItemEditView.swift:66-118`).
- Drag and drop calls `moveItemsToFolder` (`Presentation/Vault/VaultBrowserViewModel.swift:492-506`).
  `VaultRepositoryImpl.moveItemToFolder` / `moveItemsToFolder` rebuild `VaultItem` without
  `organizationId` / `collectionIds` (`:517-521`, `:530-535`). `deleteFolder` does the same
  (`:452-458`).
- Spec, `openspec/specs/org-vault-items/spec.md:19`: "Org items SHALL be excluded from folder
  selections (personal folders are not org collections)". Scenario at `:31-34`.

**Live check (2026-10-26, Vaultwarden 1.37.4, task 1.1).** With two members of one org, an org item
filed into the first member's folder (with Prizm's drag and drop, not the browser extension) showed
that folder's id in the first member's sync and null in the second member's. The official server is
source-reviewed, not tested.

## Goals / Non-Goals

**Goals**
- The folder lists in Prizm contain the same items as in the official clients.
- No local operation on folders can strip an item's organization.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Folder index without the org check

`bySelection[.folder(id)] = active.filter { $0.folderId == id }`. Counts follow. Archived items
stay excluded through the active predicate once `archived-items` lands.

### D2. Folder picker for org items

`ItemEditView` shows the folder picker whenever folders exist, for personal and org items. For org
items it goes below the collection picker. The save path is unchanged: `toRawCipher` already sends
`folderId`, and both servers store it per user. VoiceOver label "Folder", as today.

**Rejected alternative:** keep the picker hidden and allow only drag and drop. It is inconsistent
with the official form and hides an existing value from the user.

### D3. Local updates keep every field (dependency)

`deleteFolder` and the two move functions must copy the whole item and change only `folderId`.
`fix-favorite-and-folder-partial-updates` does this with a copy helper on `VaultItem`. This change
only adds a regression test for org items in folders (task 3.1).

### D4. Spec repair

`org-vault-items` and `vault-item-create` started with a delta header and no `## Purpose`, so
OpenSpec could not apply a MODIFIED delta to them. As in `password-history` task 6.4, their
structure was repaired first without requirement changes (`fix/000-openspec-main-spec-repair`);
this change then MODIFIES the folder rules in both.

The new requirement in this change states the correct rule.

## Risks / Trade-offs

- **[Low] Users see more items in folders than before.** That is the intended fix. It goes into the
  CHANGELOG as "Fixed".
- **[Low] Drag and drop of org items before `fix-favorite-and-folder-partial-updates`.** → Hard
  dependency.

## Open Questions

None.
