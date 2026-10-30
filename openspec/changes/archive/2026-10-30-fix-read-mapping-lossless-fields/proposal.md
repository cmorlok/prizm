# Proposal

## Why

**Criticality:** P0 (Critical: destroys data now)
**Findings:** S-09, S-10, S-22 (`03-sync-read.md`); W-05, W-18 (`04-write-paths.md`)

Prizm changes some item data while reading it. The next save writes the changed version back, so
the server loses data the user never touched.

`CipherMapper.map` (`Prizm/Data/Mappers/CipherMapper.swift`) does this today:

- **Custom fields without a name are dropped** (`mapFields`, `:482-483`, "name is required for
  CustomField").
- **Login URIs without a value are dropped** (`mapLogin`, `:376`).
- **Unknown custom field types become "text"** (`:486`).
- **Unknown linked-field ids become `nil`** (`:487`). The field stays "linked" but no longer points
  to anything.
- **Unknown URI match values become `nil`** (`:378`), which means "use the default".

On save, `toRawCipher` rebuilds `fields` and `login.uris` from the Domain values (`toRawLogin`,
`:673-704`; `toRawFields`, `:828-850`). Since `fix-cipher-edit-data-loss` it carries the stored
record's unknown JSON keys over, but an entry the read path dropped has no Domain value, so it is
not sent at all. Both servers replace the stored item with the request body. So one edit:

- deletes every nameless custom field and every value-less URI
- turns unknown field types into text fields
- unlinks linked fields with an unknown target
- resets unknown URI match rules to the default

Nameless fields and value-less URIs are rare. The web UI requires a field label. They come from
imports, the CLI and the API. But the loss is silent, permanent, and hits any item a Prizm user edits.

Two code comments state wrong facts (the wrong match-value comment in `RawCipher.swift` and the
"`organizationId` is sent as `nil`" comment were fixed by `fix-cipher-edit-data-loss`):
- `CipherMapper.swift:34` says the mapper filters out organisation ciphers, "personal vault only".
  Org items are mapped since `923fa5b`.
- `SyncRepositoryImpl.swift:125`, the debug log's type labels: 2 "identity", 3 "note", 4 "card".
  Correct: 2 secure note, 3 card, 4 identity.

**Origin of the current behaviour:** accidental. The dropping and defaulting came in with the first
Data layer commit `fd32450` (2026-03-16, "implement Phase 3 — Data Layer Foundation"). The only
reasoning is the comment "name is required for CustomField". No spec or design discusses nameless
fields, value-less URIs or unknown enum values.

**Relation to `fix-cipher-edit-data-loss`.** That change keeps fields Prizm does **not** model
(passkeys, password history, the archived date, and so on) by sending the original ciphertext back.
This change fixes fields Prizm **does** model but maps lossily. Both are needed before "editing
never destroys data" is true. That change lists these cases under its Known gaps and leaves them to
this one.

## What Changes

- **Nameless custom fields are kept.** The Domain field name becomes optional. The detail view shows
  such a field with the label "Unnamed field". Saving sends `name: null` back.
- **Value-less URIs are kept.** The Domain URI value becomes optional. The detail view skips the row;
  the edit form shows it as an empty row the user can fill in or remove. If the user leaves it
  empty, saving sends `uri: null` back, not an encrypted empty string, and the row is not dropped as
  a blank new row would be.
- **Unknown enum values are kept as raw integers.** Custom field type, linked-field id and URI match
  type each get an `unknown(Int)` case. The value is shown as read-only ("Unsupported field type",
  "Unknown field", "Unknown match rule"). Saving sends the original integer back.
- **Comments fixed:** `CipherMapper.swift:34` and `:482`, and the debug log type labels in
  `SyncRepositoryImpl.swift:125`.

## Capabilities

### New Capabilities
- `lossless-item-fields`: data that Prizm reads into its Domain model is written back unchanged
  unless the user edits it.

### Modified Capabilities
_None._ `vault-browser-ui` and `uri-add-remove-reorder` say nothing about nameless fields,
value-less websites or unknown values, so their requirements stay true as written.

## Non-Goals

- Fields Prizm does not model at all. That is `fix-cipher-edit-data-loss`.
- Letting the user rename, add or remove custom fields, change their type, or pick unknown match
  rules. The edit sheet keeps today's rules (field names and types are read-only, `DraftCustomField`
  in `DraftVaultItem.swift`).
- Supporting future field types. They are kept and shown read-only, not interpreted.
- URI checksum validation. That is `uri-checksum-validation`.

## Dependencies

- **Ordering (hard):** after `fix-cipher-edit-data-loss`, which has landed (fork PR #40). This
  change builds on its overlay of unknown keys and its `uriChecksum` (design D4).
- **Soft:** `uri-checksum-validation`. For items with their own key, it removes value-less URIs on
  read, as the Bitwarden SDK does. This change keeps them for items without their own key.
- **Soft:** `macos-autofill-credential-provider` must treat `nil` URIs and `unknown` match rules as
  "no match" (design D5).

## Impact

- **Domain:**
  - `CustomField.name: String?`
  - `LoginURI.uri: String?`
  - `CustomFieldType`, `LinkedFieldId`, `URIMatchType` gain `unknown(Int)` (manual
    `RawRepresentable`)
  - the matching `Draft*` mirrors
  - `normalisedForSave` keeps a value-less website row
- **Data:** `CipherMapper` read and write paths; comments in `CipherMapper.swift` and
  `SyncRepositoryImpl.swift`.
- **Presentation:**
  - `CustomFieldsSection`, `CustomFieldsEditSection`, `LoginEditForm` and the login detail rows
    handle the new optional and unknown cases
  - VoiceOver labels for the placeholder texts (§VIII)
  - DesignSystem tokens only
- **Search, favicon, Copy Website:** skip `nil` URIs (`VaultRepositoryImpl.matchesSearch`,
  `ItemRowView`, `ItemDetailView`, `VerificationCodesListView`, `PrizmApp`).
- **No new dependencies.**
- **Security review:** yes, light. The change touches the field encryption path of
  `toRawCipher` (§III), but no key handling and no new algorithm.

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Fixtures and failing round-trip tests (nameless field, nil URI, unknown ints) | 0.5 d |
| 2 | Domain types: optionals and `unknown(Int)` cases | 0.5 d |
| 3 | `CipherMapper` read and write paths | 0.5–1 d |
| 4 | Presentation: detail, edit, search; VoiceOver | 1 d |
| 5 | Comment fixes, security review, CHANGELOG | 0.5 d |
| **Total** | | **3–3.5 d** |
