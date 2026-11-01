# Proposal

## Why

**Criticality:** P2 (Medium: wrong behaviour users notice)
**Findings:** S-14 (`03-sync-read.md`); CF-10 (`06-client-features.md`)

Bitwarden has an **Archive**. Archived items stay in the vault but leave the everyday lists. They are
not suggested for autofill, and a separate Archive view lists them. Both target servers support it:
- the official server
- the official server from v2025.10.0
- Vaultwarden from 1.36.0; 1.37.3 and 1.37.4 also turn on the clients' archive feature flag

Older servers have no archive. On them Prizm behaves as today (design.md D5).

Prizm ignores archive state. `RawCipher` has no `archivedDate`, so archived items show up as normal
items in:
- All Items and Favorites
- the type lists, folders, collections and organizations
- the Codes list

A user who archived 200 old logins in the browser extension sees all 200 again in Prizm, with no way
to tell which ones are archived. Prizm also has no way to archive or unarchive.

Before `fix-cipher-edit-data-loss` (merged), editing an archived item in Prizm also unarchived it
(a `PUT` without `archivedDate` clears the archive state on Vaultwarden, `ciphers.rs:580-586`). That
change now sends `archivedDate` back as received. This change is the read side and the UI.

**Origin of the current behaviour:** accidental. Archive came to Bitwarden after Prizm's sync model
was written (`fd32450`, 2026-03-16). No Prizm spec or design mentions it. The write-side drop was
found in the `fix-cipher-edit-data-loss` research; the read side was found in this audit.

## What Changes

- **Read `archivedDate`** from the sync response and keep it on `VaultItem`.
- **Hide archived items from the everyday lists**:
  - All Items and Favorites
  - the type lists, folders, collections and organizations
  - the Codes list
  - search outside the Archive view

  This matches the official filter.
- **New sidebar entry "Archive"** with a count. It lists archived items that are not deleted.
  Search within it works as in other lists.
- **Trash** keeps showing deleted items whether archived or not, as in official clients. Restoring
  an archived item puts it back in the Archive.
- **Archive and Unarchive actions** in the item's context menu and detail toolbar:
  - they call `PUT /api/ciphers/{id}/archive` and `/unarchive`
  - both are always offered, without a premium check: no server enforces one (Christian,
    2026-10-30: Prizm only reacts to what the server enforces); a refusal shows the server's message
- **AutoFill:** archived items must never be suggested. Recorded for
  `macos-autofill-credential-provider`.

## Capabilities

### New Capabilities
- `archived-items`: archive state is read, respected in every list, and can be changed.

### Modified Capabilities
_None as delta._ Related existing specs, to update when this change is archived:
- `openspec/specs/vault-browser-ui` (sidebar entries)
- `openspec/specs/vault-folder-organization`
- `openspec/specs/org-vault-items` (list membership)
- `openspec/specs/global-search`

## Non-Goals

- Bulk archive or unarchive of several selected items. Possible follow-up; the bulk endpoints exist
  on both servers.
- The official "subscription ended" banner for users who lost premium with archived items left.
- Write-side preservation of `archivedDate` on edit. That is `fix-cipher-edit-data-loss`.

## Dependencies

- **Hard (merged):** `fix-cipher-edit-data-loss` preserves `archivedDate` on `PUT`.
- **Soft:** `macos-autofill-credential-provider` must exclude archived items from matching and from
  the credential identity store.
- **Soft:** `fix-favorite-and-folder-partial-updates`. Once the star uses the partial endpoint,
  favouriting an archived item no longer sends a full `PUT` at all.
- **Soft:** `fix-sync-decoding-resilience`. Placeholder items follow the same archive filter when
  their `archivedDate` decodes.

## Impact

- **Data:**
  - `RawCipher.archivedDate`, read as a date string (a `JSONValue?` since
    `fix-cipher-edit-data-loss`)
  - `CipherMapper` maps the date
  - `VaultRepositoryImpl.buildIndexes` filters
  - two new `PrizmAPIClient` calls
- **Domain:**
  - `VaultItem.archivedDate: Date?` (`isArchived` computed)
  - `SidebarSelection.archive`
  - `ArchiveItemUseCase` / `UnarchiveItemUseCase`
- **Presentation:**
  - sidebar entry and count
  - Archive and Unarchive actions
  - "Archived" badge in the detail header
  - VoiceOver labels
  - DesignSystem tokens only
- **No new dependencies.**
- **Security review:** no. No crypto, keys or secrets are touched; `archivedDate` is plaintext
  metadata.

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Verify server behaviour and record it | 0.5 d |
| 2 | Decode `archivedDate`; Domain fields | 0.5 d |
| 3 | List filtering and Archive sidebar entry | 0.5–1 d |
| 4 | Archive and Unarchive actions (API, use cases, UI) | 1 d |
| 5 | VoiceOver, XCUITest journey, CHANGELOG | 0.5 d |
| **Total** | | **3–3.5 d** |
