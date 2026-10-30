# Design

## Context

**Official behaviour.** Sources: `sdk-internal` and `clients` at HEAD 2026-10-23.

- **Field name and URI value are optional.**
  - SDK `Field { name: Option<EncString>, value: Option<EncString>, type, linked_id: Option<LinkedIdType> }`
    (`sdk-internal/crates/bitwarden-vault/src/cipher/field.rs:52-60`).
  - `LoginUri { uri: Option<EncString>, match: Option<UriMatchType>, uri_checksum: Option<EncString> }`
    (`cipher/login.rs:39-43`).
  - The decrypted views keep `None` as `None` (`field.rs:66-74`, `login.rs:51-55`). Encrypting a
    view writes `None` back as `None` (`field.rs:108-121`, `login.rs:420-432`). So the SDK keeps
    nameless fields and value-less URIs through an edit.
- **Unknown enum values are not kept by the official clients either.** The audit row W-05 says the
  SDK "keeps them as they are". That is only true for the optional values. For unknown integers:
  - SDK: an unknown field `type` fails with `MissingFieldError("type")` (`field.rs:207-219`).
    The same goes for an unknown `linked_id` (`field.rs:199-202`, `linked_id.rs:71-77`) and an
    unknown URI `match` (`login.rs:637`, `:644-657`). The error fails the whole item: the SDK
    can't parse it, so the client can't show or edit it.
  - TypeScript clients: an unknown field type is turned into Text before the item reaches the SDK
    (`clients/libs/common/src/vault/enums/field-type.enum.ts:21-30`, used in
    `models/domain/field.ts:74`). An edit in those clients turns it into a text field.
  - So no official client keeps an unknown integer through an edit. Prizm keeping it (D3) is
    stricter than official. It is cheap, and it avoids changing data that a newer client wrote.
- **Correct URI match values.** `UriMatchType`: Domain 0, Host 1, StartsWith 2, Exact 3,
  RegularExpression 4, Never 5 (`login.rs:25-32`;
  `clients/libs/common/src/models/domain/domain-service.ts:14-21`).
- **Known field types and linked ids.** Field types are 0–3 (`field.rs:24-33`). Linked ids are
  100–101, 300–305 and 400–418 (`cipher/linked_id.rs`). Prizm's enums match these exactly (audit 03,
  "Matches official").
- **Checksum of a value-less URI.** `generate_checksum` does nothing when `uri` is `None`
  (`login.rs:75-82`), so the SDK never invents a checksum for it. For items with their own key,
  `remove_invalid_checksums` drops a value-less URI on read (`login.rs:57-60`, `cipher.rs:812-818`).
  See `uri-checksum-validation`.

**Prizm today** (after `fix-cipher-edit-data-loss`).
- Read, `Prizm/Data/Mappers/CipherMapper.swift`:
  - `mapLogin`, `:375-380`: `compactMap` drops URIs with `uri == nil` and maps an unknown `match`
    to `nil`.
  - `mapFields`, `:480-490`: `compactMap` drops fields with `name == nil`, maps an unknown `type` to
    `.text` and an unknown `linkedId` to `nil`.
- Write, same file:
  - `toRawLogin`, `:673-704`: drops empty addresses, encrypts every other one and computes its
    `uriChecksum`. Each address takes the unknown keys of the stored address with the same text;
    `readStoredURIs` (`:873-882`) skips stored addresses without a value.
  - `toRawFields`, `:828-850`: always encrypts the name. Each field takes the unknown keys of the
    stored field with the same name and type; `readStoredFields` (`:854-866`) skips stored fields
    without a name and reads an unknown type as `.text`.
- Domain:
  - `CustomField.name: String` (`Domain/Entities/CustomField.swift`)
  - `LoginURI.uri: String` (`Domain/Entities/VaultItem.swift`)
  - `CustomFieldType`, `LinkedFieldId`, `URIMatchType` are `Int` raw-value enums without an
    "unknown" case
  - `normalisedForSave` (`Domain/Utilities/ItemFieldNormalisation.swift`) drops blank website rows
    before a save.
- Edit: `DraftCustomField.name` and `type` are read-only (`DraftVaultItem.swift`). URIs can be added,
  removed and reordered (`LoginEditForm.swift`).
- Stale comments:
  - `CipherMapper.swift:34` ("Filter out organisation ciphers … personal vault only"; org items are
    mapped since `923fa5b`)
  - `CipherMapper.swift:482` ("name is required for CustomField")
  - `SyncRepositoryImpl.swift:125` (debug type labels swapped: 2/3/4)

## Goals / Non-Goals

**Goals**
- Every value the read path puts into the Domain model goes back to the server unchanged unless
  the user changed that value.
- Unknown values are visible as "unsupported" and are never interpreted.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Optional name and URI value in the Domain model

`CustomField.name` and `LoginURI.uri` become `String?`, and so do their `Draft*` mirrors. Domain
stays Foundation-only.

**Rejected alternative:** keep the Domain types and park nameless fields and value-less URIs in a
Data-side table, then merge them back on save. That needs positional merging against a list the
user can reorder (URIs). It would also keep them invisible, so the user could not see or remove
them.

### D2. Presentation of the optional values

- **Nameless custom field.** Detail and edit show the label "Unnamed field" in secondary style. The
  VoiceOver label is "Unnamed field" plus the value. The name stays read-only in edit, as for all
  fields today.
- **Value-less URI.**
  - The detail view skips the row, because there is nothing to open or copy.
  - The edit form shows it as an empty row with the placeholder "No website".
  - `DraftLoginURI` remembers that the row was read without a value. While such a row is empty
    (untouched, or typed into and cleared again), it stays `nil`: `normalisedForSave` keeps it,
    and it is saved as `uri: null` with its match value and checksum unchanged (D4). A blank *new*
    row is still dropped, as today.
  - If the user types a value, it is encrypted as usual.
  - The user can remove the row.
- **Blank new URIs** (audit W-17) are out of scope. This change only guarantees that an *existing*
  `nil` stays `nil`.

### D3. `unknown(Int)` cases for the three enums

- `CustomFieldType`, `LinkedFieldId` and `URIMatchType` get a case `unknown(Int)`. They conform to
  `RawRepresentable` by hand, and `init(rawValue:)` never fails.
- The mapper stores the raw integer. `toRawCipher` writes `rawValue`, which is the original integer
  for unknown values.
- Presentation:
  - A field of unknown type shows its decrypted value read-only, labelled "<name> (Unsupported
    field type)". The value is masked and revealable like a hidden field, because a newer type may
    hold a secret; the edit form shows only "Unsupported field type", not the value.
  - A linked field with an unknown target shows "→ Unknown field". Today's fallback text is
    "Unknown Field" (`CustomFieldsSection.swift:69`); the case now has a real meaning.
  - A URI with an unknown match rule shows "Unknown match rule" in the edit picker as a disabled
    current value. The user can pick a known rule, which replaces it.
- Every `switch` over these enums gets an explicit `.unknown` branch. No `default:`, so the compiler
  flags new call sites.
- Equality: with a hand-written `RawRepresentable`, the standard library's `==` and `hash(into:)`
  for `RawRepresentable` apply, which compare raw values. `.unknown(n)` is only ever created for an
  `n` without a known case, so equal raw values always mean the same case.

**Rejected alternatives**
- *Keep mapping to a known value (today).* This changes data on save.
- *Fail the item, like the SDK.* The item would disappear from Prizm (audit S-07) over a value
  Prizm doesn't even need to read.

### D4. Interaction with `fix-cipher-edit-data-loss`

- That change computes a fresh `uriChecksum` for every address on every save and create, and never
  sends an address without a value (its design D3, "URIs without a value are never sent"). Its Known
  gaps list value-less URIs and nameless custom fields as dropped on read and leave them to this
  change.
- This change lifts that rule for an address that was read without a value: it is sent with
  `uri: null`, no checksum is computed for it, and the stored entry's `uriChecksum` (usually `nil`)
  goes back as received. That matches SDK `generate_checksum`, which does nothing when `uri` is
  `None` (`login.rs:75-82`).
- Unknown keys: its overlay pairs draft and stored entries by content (its design D2). This change
  extends the pairing to the entries the read path used to skip: a value-less draft address takes
  the next unused stored address without a value (and its checksum), a nameless draft field the next
  unused stored field without a name and of the same type. The stored type is read as the mapper
  reads it, so an unknown type compares as `.unknown(n)`, not as `.text`.
- Elements are no longer dropped, so the element order on read equals the order on write.
- Accepted: once the user fills in a value for an address that was read without one, it no longer
  pairs with the stored value-less entry (pairing is by content), so that entry's unknown keys are
  not sent. Same as for any other edited address in that change (its design D2).

### D5. Consumers of the new optionals

- `VaultRepositoryImpl.matchesSearch` skips `nil` URIs.
- Favicon lookup (`ItemRowView`, `ItemDetailView`, `VerificationCodesListView`) and Copy Website
  (`PrizmApp`) use the first non-`nil` URI.
- `macos-autofill-credential-provider` must treat `nil` URIs and `.unknown` match rules as "no
  match". This is noted there as a soft dependency. It is not implemented here.

## Risks / Trade-offs

- **[Low] Wider Domain change.** Optionals and new enum cases touch several Presentation files.
  → The compiler finds every call site, and the unit tests cover each mapping.
- **[Low] Stricter than official for unknown integers.** A later official client may still turn
  them into text. Prizm can't prevent that, but it no longer does it itself.
- **[Low] Already-damaged items.** Fields and URIs deleted by earlier Prizm edits can't be
  restored. The CHANGELOG says so.

## Open Questions

None. Decided 2026-10-30: a nameless custom field cannot be deleted in the edit form, as no custom
field can today; a later "edit custom fields" change decides that for all fields.
