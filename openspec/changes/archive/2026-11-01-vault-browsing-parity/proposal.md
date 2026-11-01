# Proposal

## Why

**Criticality:** P3 (Low)
**Findings:** CF-14, CF-17, CF-19, CF-20, CF-21 (`06-client-features.md`); W-15 (`04-write-paths.md`,
custom-field part)

Browsing and light editing in Prizm differ from the official apps in small ways that users who
switch between clients notice:

- **Search finds less.** Prizm matches one substring against name, login username and full URI,
  cardholder, identity email and company (`Data/Repositories/VaultRepositoryImpl.swift:1459-1474`, `matchesSearch`).
  It does not search notes, card brand or last four digits, identity first and last name, or SSH
  key fingerprints. "github work" finds nothing, because the whole query must match one field.
  "Müller" does not find "Muller". Official clients split the query into terms and normalise
  diacritics.
- **Missing filters.** No "No folder" view and no "My vault" (personal items only) view. Official
  desktop has both.
- **Folder and collection trees merge names by case.** "Work/A" and "work/B" end up under one
  "Work" node (`Domain/Entities/FolderTreeNode.swift:27-38`,
  `Domain/Entities/CollectionTreeNode.swift:28-50`). Official clients keep them apart.
- **Sorting.** "Item 10" sorts before "Item 2"; two logins named "Google" appear in random order
  (`VaultRepositoryImpl.swift:1405-1407`, `sorted`). Official clients sort numerically with the locale collator
  and break ties by username.
- **Custom fields cannot be added, renamed, removed or reordered.** Only existing values can be
  edited. Users must switch to another client to add a security question or remove an old field.

Some differences are deliberate and stay; this change records them so they stop showing up as
audit findings: ⌥ peek, full-URI search, no "Unassigned" filter, virtual parent folders.

### Origin of the current behaviour

| Item | Origin | Evidence |
|---|---|---|
| Search fields (CF-14) | Deliberate, fields chosen per type; notes excluded without a reason | `openspec/changes/archive/2026-03-15-vault-browser-ui/tasks.md:83` ("per-type field matching"); `openspec/specs/global-search/spec.md:42` |
| ⌥ peek (CF-17) | Deliberate | `openspec/specs/alt-key-password-peek/spec.md:4` "The system SHALL temporarily reveal all masked field values while the user holds the Option (⌥) key" |
| No "No folder" (CF-19) | Deliberate, no reason given | `openspec/specs/vault-folder-organization/spec.md:4` "Items without a `folderId` SHALL NOT appear under any folder" |
| No "My vault" (CF-19) | Accidental | no trace |
| Tree naming (CF-20) | Accidental | comment claims to mirror Bitwarden's "/" convention (`CollectionTreeNode.swift:5-6`) |
| Sorting (CF-21) | Accidental | no trace |
| Custom fields fixed (W-15) | Deliberate (deferred) | `openspec/changes/archive/2026-03-23-edit-vault-items/design.md:21` "Adding, removing, or reordering custom fields — existing custom fields are editable but the list is fixed"; `DraftVaultItem.swift:35-39`; `CustomFieldsEditSection.swift:11` |

## What Changes

Change:
- **Search:** split the query into terms, every term must match; ignore case and diacritics;
  also search notes, card brand and last four digits, identity first and last name, SSH key
  fingerprint.
- **Filters:** add "No folder" at the end of the Folders section and "My vault" at the top of the
  Organizations section.
- **Trees:** match folder and collection path segments case-sensitively.
- **Sorting:** numeric, locale-aware name order; logins with the same name ordered by username.
- **Custom fields:** add (text, hidden, checkbox, linked), rename, remove, and move up or down in
  the edit sheet. The type is fixed once a field exists, as in official clients.

Keep, documented as deliberate differences (design.md D1 table):
- ⌥ peek, with the exemptions delivered by `enforce-master-password-reprompt` and
  `honour-org-item-permissions`.
- Full-URI substring search (finds more than official hostname matching).
- No "Unassigned" filter (official desktop does not have one either).
- Virtual parent nodes for nested folders and collections.
- No `>` full-text (Lunr) search syntax, no search by item ID.

## Capabilities

### New Capabilities
- `vault-browsing-parity`: search matching, the "No folder" and "My vault" filters, tree
  segment matching, list sorting, and custom-field structure editing.

### Modified Capabilities
_None as deltas._ Related existing specs, to be reconciled at archive time:
`openspec/specs/global-search`, `openspec/specs/vault-folder-organization` (the "SHALL NOT appear
under any folder" sentence gains the "No folder" view), `openspec/specs/org-collections`,
`openspec/specs/alt-key-password-peek`, `openspec/specs/vault-browser-ui`.

## Non-Goals

- Re-prompt and hide-password gating of peek, reveal and copy: `enforce-master-password-reprompt`,
  `honour-org-item-permissions`.
- Showing org items in personal folders: `org-items-in-personal-folders`.
- Other W-15 items: adding or editing TOTP seeds (deliberate, `specs/001-totp-verification-codes/spec.md:140`;
  also a non-goal of `totp-parity`), the re-prompt toggle (`enforce-master-password-reprompt`),
  clone, bulk delete and bulk restore. Clone and bulk actions are listed in README "Known
  Limitations" by this change and left for a maintainer decision.
- Changing a custom field's type after creation (official clients do not allow it either).
- Search inside custom fields, attachments' file names or password history.

## Dependencies

- **Hard (custom fields only), merged:** `fix-cipher-edit-data-loss` (safe full `PUT`) and
  `fix-read-mapping-lossless-fields` (nameless fields and unknown field types survive a round
  trip).
- **Merged:** `org-items-in-personal-folders` (folder lists hold org items too).
- **Soft:** `password-history` (removing, renaming or changing a hidden field records it in the
  history, as official clients do; matched by name, as the SDK); `honour-org-item-permissions`
  (hidden fields read-only when the user may not view passwords). `archived-items` (batch 3) also
  adds a `SidebarSelection` case and hash value; whichever lands second rebases (hash values 10 for
  `.archive`, 11 and 12 here).
- The search, filter, tree and sort parts have no dependencies and can ship alone.

## Impact

- **Domain:** `SidebarSelection.noFolder`, `.myVault`; search term matching and highlight ranges in
  a Domain utility (`VaultSearchMatcher`) so it is unit-testable; `DraftCustomField.name` and
  `linkedId` become `var`, with a draft-only id, the name it was read with and a "new" flag;
  `LinkedFieldId.options(for:)`. Foundation only.
- **Data:** `VaultRepositoryImpl` (`buildIndexes`, `sorted`, `matchesSearch`, folder, organization
  and collection order); `CipherMapper.toRawFields` (pairs fields by the name they were read with).
- **Presentation:** `SidebarView` (two rows), `CustomFieldsEditSection` (add, rename, remove,
  move up/down, VoiceOver labels and announcements), search highlighting per term. DesignSystem
  tokens only.
- **No new dependencies.**
- **Security review:** no. No crypto, keys or tokens. Custom-field writes reuse the existing
  encrypt-and-save path; the review of `fix-cipher-edit-data-loss` covers it.

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Search matcher and fields, highlighting per term | 1 d |
| 2 | "No folder" and "My vault" | 0.75 d |
| 3 | Case-sensitive tree segments | 0.25 d |
| 4 | Sorting | 0.25 d |
| 5 | Custom fields: add, rename, remove, reorder, accessibility | 2–2.5 d |
| 6 | Docs (README, specs), UI tests, CHANGELOG | 0.5 d |
| **Total** | | **4.75–5.25 d** |
