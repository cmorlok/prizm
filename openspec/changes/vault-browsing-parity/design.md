# Design

## Context

Sources: `$SRC/clients` at `c0ca72a0` (2026-10-23). Prizm paths are relative to `Prizm/`.

### Official behaviour

**Search** (`clients/libs/common/src/vault/services/search.service.ts`)
- A query starting with `>` goes to Lunr full-text search (`:67`, `:90-98`). Otherwise basic search.
- Basic search splits the lower-cased, diacritic-normalised query on whitespace; **every** term
  must match at least one target (`:108-171`). Targets: name; item ID prefix if the term has at
  least 8 characters; the type's subtitle; login URI **hostnames**; notes.
- Normalisation: `normalize("NFD")` and strip U+0300–U+036F (`:206-208`).
- Subtitles: login username; card brand plus `*` and last four digits
  (`libs/common/src/vault/models/view/card.view.ts:51-60`); identity first and last name
  (`identity.view.ts:71-85`); SSH key fingerprint (`ssh-key.view.ts:31-33`).

**Filters**
- "No folder": the folder service appends a folder view with no ID named "No folder"
  (`libs/common/src/vault/services/folder/folder.service.ts:298-300`). The filter matches items
  whose `folderId` is null or empty (`libs/vault/src/models/vault-filter.model.ts:134-138`).
- "My vault": an organization-filter node with ID `MyVault` (`libs/vault/src/services/vault-filter.service.ts:306-308`)
  that matches items without `organizationId` (`vault-filter.model.ts:165-168`). Desktop uses it
  (`apps/desktop/src/vault/app/vault-v3/vault-filter/vault-filter.component.ts:86,100`).
- "Unassigned" (org item with no collection): exists in the filter model (`vault-filter.model.ts:149-153`)
  but the desktop collection tree does not offer it (`vault-filter.service.ts:336-346` builds only
  real collections). It is offered in the web **Admin Console** (`apps/web/src/app/admin-console/organizations/collections/`).
  The audit row CF-19 ("Both filters exist") is therefore only partly right for desktop.

**Nested names** (`libs/common/src/vault/service-utils.ts:16-66`, `nestedTraverse`)
- Segments are compared with `===` (case-sensitive).
- A missing parent is not created: "A/B" without an "A" becomes a single node named "A/B".

**Sorting** (`libs/common/src/vault/services/cipher.service.ts:1122-1160`)
- `Intl.Collator(locale, { numeric: true, sensitivity: "base" })`
  (`libs/common/src/platform/services/translation.service.ts:103-106`).
- Two logins with equal names are compared again on name + username.

**Custom fields in the item form** (`libs/vault/src/cipher-form/components/custom-fields/`)
- Add with a type and a label (`custom-fields.component.ts:280-305`); linked fields get the first
  linked option of the item type (`:291-294`).
- Edit the label; the type control is disabled when editing (`add-edit-custom-field-dialog.component.ts:89-92`).
- Remove (`custom-fields.component.ts:274-277`).
- Reorder by drag and drop or by move-up/move-down buttons, with screen-reader announcements
  "reorderFieldUp/Down" (`:310-346`).
- Hidden fields are read-only when the item's `viewPassword` is false (`:157-163`, `:198-203`).

### Prizm today

- Search: `VaultItem.matchesSearch(query:)` with `localizedCaseInsensitiveContains` (case-
  insensitive, diacritic-sensitive), one substring for the whole query; fields as listed in the
  proposal (`Data/Repositories/VaultRepositoryImpl.swift:595-614`). Results are scoped to the
  current sidebar selection; matched text in name and subtitle is bold (`openspec/specs/global-search/spec.md:36-48`).
- Filters: `SidebarSelection` has `allItems`, `favorites`, `type`, `folder`, `trash`,
  `verificationCodes`, `organization`, `collection` (`Domain/Entities/SidebarSelection.swift:46-62`).
  `==` is written by hand and ends in `default: return false` (`:83-96`), so a case missing there
  compiles and is unequal to itself; `hash(into:)` and `displayName` are exhaustive. Folder lists
  include org items (`VaultRepositoryImpl.swift:188-192`, `org-items-in-personal-folders`).
- Highlighting: `highlightedText` bolds only the first match, case-insensitive only
  (`ItemRowView.swift:70-82`); a secure note's subtitle is the first 30 characters of its notes
  (`:107-110`).
- Trees: case-insensitive segment match, virtual parents, empty segments dropped
  (`FolderTreeNode.swift:27-38`, `CollectionTreeNode.swift:17-50`). Two folders with the same full
  name collide: `FolderTreeNode.insertNode` replaces the node (`:27-29`), so one becomes
  unreachable; `CollectionTreeNode` appends a sibling (`:36-39`).
- Sorting: `localizedCaseInsensitiveCompare` on name only (`VaultRepositoryImpl.swift:542-544`).
  Not numeric; no tie-breaker.
- Custom fields: `DraftCustomField.name`, `type` and `linkedId` are `let` (`Domain/Entities/DraftVaultItem.swift:49-60`).
  `CipherMapper.toRawFields` gives a draft field the unknown keys of the stored field with the same
  name and type (`CipherMapper.swift:895-937`); its comment relies on the sheet never adding,
  removing or reordering fields. Linked fields are shown read-only (`CustomFieldsEditSection.swift:63-68`).
  `hasChanges` is `draft != original` (`ItemEditViewModel.swift:228-229`), and a folder- or
  favourite-only save goes through `/partial` only when `perUserChangeOnly == draft` (`:544-547`).
  `CustomFieldsEditSection` hides itself when there are no fields and offers no add, remove or
  reorder (`Presentation/Vault/Edit/CustomFieldsEditSection.swift:5-27`). URIs already have add,
  remove, move up and move down (`Presentation/Vault/Edit/LoginEditForm.swift:28-45`,
  `openspec/specs/uri-add-remove-reorder`).
- ⌥ peek: `MaskedFieldView` shows plaintext while ⌥ is held (`Presentation/Components/MaskedFieldView.swift:71-74`).

## Goals / Non-Goals

**Goals**
- A query that finds an item in the official app finds it in Prizm, except for the documented
  differences.
- Every deliberate difference has a written reason.
- Custom fields can be maintained in Prizm without switching clients.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Decision per finding

| Finding | Topic | Decision | Reason |
|---|---|---|---|
| CF-14 | Multi-term AND, diacritic-insensitive | **change** | Cheap, and users type "github work" or "Muller". |
| CF-14 | Notes, card brand + last 4, identity name, SSH fingerprint | **change** | Official targets; notes exclusion had no recorded reason. |
| CF-14 | Full URI instead of hostname | **keep, documented** | Finds a superset (paths, ports). Hostname-only would make Prizm find less. |
| CF-14 | Cardholder, identity email and company | **keep, documented** | Already searched; removing them would make Prizm find less. |
| CF-14 | ID prefix, `>` Lunr syntax | **keep, documented** | Prizm never shows item IDs; Lunr syntax is a power feature with no demand. |
| CF-17 | ⌥ peek reveals all masked fields of the selected item | **keep, documented** | Deliberate Prizm feature (`alt-key-password-peek`). Its bypass of re-prompt and hide-passwords is closed by `enforce-master-password-reprompt` (D4: peek ignored for unverified protected items) and `honour-org-item-permissions` (no peek for concealed fields). |
| CF-19 | "No folder" | **change** | Official desktop has it; the old rule had no reason. |
| CF-19 | "My vault" | **change** | Official desktop has it; Prizm already has per-org views, so the personal view is the missing counterpart. |
| CF-19 | "Unassigned" | **keep, documented** | Official desktop does not offer it either (Admin Console only). |
| CF-20 | Case-insensitive segment match | **change** | Merging "Work" and "work" puts items under a parent that is not theirs. |
| CF-20 | Virtual parent nodes | **keep, documented** | Display only; groups "A/B" and "A/C" under "A" even without an "A" folder. Official shows "A/B" flat. Virtual nodes stay non-selectable and have no count. |
| CF-20 | Empty segments dropped ("A//B") | **keep** | Edge case; official behaviour for it is undefined (would look for a node named ""). |
| CF-21 | Numeric, locale-aware order; username tie-break | **change** | One-line change, matches official. |
| W-15 | Custom fields add, rename, remove, reorder | **change** | The v1 deferral has run its course; URIs already got the same treatment. |
| W-15 | Change a field's type | **keep** | Official disables it too. |

### D2. Search matcher in the Domain layer

`VaultSearchMatcher` (Domain, Foundation only) splits the query on whitespace (empty terms dropped).
An item matches when every term is found in at least one target. For speed the list filter
compares folded copies (case and diacritics folded once per item into a search key, then
`String.contains`); highlighting uses
`range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: .current)` on the
original string, so ranges always refer to the original text (folding first would break offsets,
e.g. ß → ss). Both fold case and diacritics, so a listed row highlights its match; they can differ
only where folding changes a character's length (ß), where the row is still listed. Targets per
type:

| Type | Targets |
|---|---|
| all | name, notes |
| login | username, every URI (full string) |
| card | cardholder name, brand, the last four digits of the number (never the full number) |
| identity | first name, last name, email, company |
| SSH key | fingerprint |
| secure note | (name and notes only) |

Highlighting: each term is bolded wherever it occurs in name and subtitle. A secure note's subtitle
is the start of its notes, so a match there is highlighted; a match only in the part of the notes
the list does not show has no highlight (documented in the spec).

**Rejected:** porting the official target list exactly (hostname only, no email or company). It
would make Prizm find less than today.

Performance: matching runs on the in-memory vault on each keystroke as today, O(items × fields).
A `measure {}` test with 5,000 generated items guards against regressions with a generous bound
(CI runners are slow); the number on the developer Mac is recorded by hand. Folded targets are
cached per item (one search key, built in `buildIndexes`, dropped on lock): matching every target
on each keystroke took about 70 ms per query for 5,000 items. Measured on the developer Mac
2026-10-30 (Debug build, 5,000 generated items): one query 5–16 ms, building the keys under 60 ms.

### D3. "No folder" and "My vault"

- `SidebarSelection.noFolder`: last row of the Folders section, label "No Folder", SF Symbol
  `folder.badge.minus`, with a count badge. Content: active items with no `folderId`, org items
  included (`org-items-in-personal-folders` is merged). Shown only when the user has at least one
  folder (Christian, 2026-10-30): without folders it would list the same items as All Items, the
  same reason "My Vault" is hidden without organizations.
- `SidebarSelection.myVault`: first row of the Organizations section, shown only when the user
  belongs to at least one organization (otherwise it equals All Items). Content: active items with
  no `organizationId`.
- Both rows reuse `SidebarRowView` (title plus count badge, as every other row) and get
  accessibility identifiers. Neither is a drop target or has a context menu.
- `.noFolder` and `.myVault` are added to `displayName`, the hand-written `==` and `hash(into:)`
  (values 11 and 12; 10 is `.archive` from `archived-items`).
- When the selected row disappears (the last folder is deleted, or a sync removes every folder or
  organization), the selection becomes All Items, as for a deleted folder
  (`VaultBrowserViewModel.swift:817-819`).

### D4. Case-sensitive segments

`FolderTreeNode.insertNode` and `CollectionTreeNode.insertNode` compare segments with `==`.
Sorting of sibling nodes stays case-insensitive and locale-aware (D5), so "work" and "Work" appear
next to each other as two nodes. Two folders with identical full names both appear (siblings, as
`CollectionTreeNode` already does), instead of one replacing the other.

### D5. Sorting

`sorted(_:)` uses `localizedStandardCompare` (Finder-style: numeric, locale-aware). When two
logins have equal names, compare `name + username` (a missing username counts as ""). Items that
still compare equal keep their sync order (stable sort). Tree siblings, `folders()`,
`organizations()` and `collections()` use the same comparison.

**Rejected:** `Collator` via ICU directly. `localizedStandardCompare` already gives numeric,
locale-aware order without extra code.

### D6. Custom-field editing

- `DraftCustomField.name` and `linkedId` become `var`; `type` stays `let`. Every draft field (read
  and new) carries a draft-only `id` (UUID) so SwiftUI identity survives reorder; the id is left
  out of `==`, as `DraftLoginURI` does (`DraftVaultItem.swift:39-42`), so opening and cancelling
  without edits is not a change and a folder-only save still goes through `/partial`.
- Each draft field also keeps `originalName` (the name it was read with) and `isNew`.
  `toRawFields` pairs an existing field with its stored field by (`originalName`, type), so a
  rename keeps the field's unknown keys; a new field gets none, even when named like a removed one.
  Each read field also keeps `originalIndex`, its read position: the stored field at that position
  is taken first when it still matches, so two fields with the same name keep their own keys when
  the user reorders them (review, 2026-10-31); otherwise the first unused match.
  The comment at `CipherMapper.swift:899` is updated.
- Names: a field that had a name on read must keep one (Save is disabled while it is empty, and
  the row says a name is required); a field read without a name whose text is typed and then
  cleared goes back to nil, like `DraftLoginURI.text`. A new field needs a name.
- Unknown-type fields (kept by `fix-read-mapping-lossless-fields`) can be moved, removed and
  renamed; their value is never shown or edited.
- The Custom Fields card is always shown in the edit sheet, with an "Add Field" menu button:
  Text, Hidden, Checkbox, Linked (Linked only for login, card and identity). The linked row is a
  Picker of `LinkedFieldId.options(for: ItemType)` (Domain, the SDK's lists); the first is
  preselected, as official, and the user can pick another.
- Each row: name text field, value editor by type, "Move Up", "Move Down", "Remove" buttons, the
  same controls and layout as URI rows. VoiceOver labels name the field ("Move Security question
  up"); after a move, post an announcement "Security question moved to position 2 of 4", as the
  official form does. The announcement text comes from a plain function with unit tests.
- Removing a field asks for no confirmation (the sheet can still be cancelled), matching URI rows.
- Validation: a field may have an empty name only if it already had one on read
  (`fix-read-mapping-lossless-fields` keeps those); a new field needs a name.
- Hidden fields: when the item's password is hidden by collection permission, the row is
  read-only and cannot be removed. That rule comes with `honour-org-item-permissions` (not merged);
  until then every field is editable, as today's value editing.
- Password history: when a hidden field's value changes, or a hidden field is removed or renamed,
  the `password-history` change records `"<name>: <old value>"` (matched by name, as the SDK, so a
  rename is a removal). Until that change is merged, no history is written; whichever lands second
  adds the combined test (task 5.6).
- Encryption and save: unchanged path. Names and values are encrypted with the item's effective
  key by `CipherMapper.toRawCipher`; field order is the array order sent in the `PUT`.

### D7. Documentation of kept differences

README "Known Limitations" gets one line per kept difference that users may notice: no clone, no
bulk delete or restore, no adding TOTP seeds, ⌥ peek (already under Shortcuts). The capability spec
states the search targets and the virtual-parent rule.

## Risks / Trade-offs

- **[Medium] Custom-field edits on items Prizm cannot fully read.** → `fix-cipher-edit-data-loss`
  and `fix-read-mapping-lossless-fields` are merged; renames keep unknown keys through
  `originalName` (D6).
- **[Low] Search returns more results** (notes, multi-term). → That is the intent; highlighting
  shows why a result matched, except for note-only matches.
- **[Low] Case-sensitive trees show two "Work" nodes** where users had one. → Matches what official
  clients show; users can rename one.

## Open Questions

None. Closed 2026-10-30 (Christian): clone and bulk delete/restore stay out (README, D7); "No Folder"
is hidden when the user has no folders (D3).
