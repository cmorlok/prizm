# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Failing tests (0.5 d)

- [ ] 1.1 Add a `RawCipher` fixture: a login with a custom field `name: null`, a URI `uri: null` with `match: 3`, a field with `type: 9`, a linked field with `linkedId: 999`, and a URI with `match: 7`.
- [ ] 1.2 Failing test: map the fixture, change only the username, run `toRawCipher(_:overlaying:...)`. Assert that:
  - the nameless field is present with `name == nil`
  - the `nil` URI is present with `uri == nil`, its original `match` and its stored `uriChecksum`
  - `type == 9`, `linkedId == 999` and `match == 7` are unchanged
  - element order is unchanged
  - unknown JSON keys of the nameless field and the value-less URI are carried over (D4)
- [ ] 1.3 Failing test: the same fixture through `DraftVaultItem`, `normalisedForSave` and back to `VaultItem` (the post-save path in `VaultRepositoryImpl.update`) keeps all five values.

## 2. Domain types (0.5 d)

- [ ] 2.1 `CustomField.name: String?`, `LoginURI.uri: String?`, plus the `DraftCustomField` and `DraftLoginURI` mirrors. `DraftLoginURI` remembers a row read without a value; while that row is empty its `uri` stays `nil` (D2). `DraftLoginURI.init()` for a new row keeps today's `""` default (W-17 is out of scope).
- [ ] 2.2 `CustomFieldType`, `LinkedFieldId`, `URIMatchType`: add `unknown(Int)` with a hand-written `RawRepresentable` whose `init(rawValue:)` never fails. Unit tests: every known raw value round-trips; unknown values round-trip; `LinkedFieldId.unknown.displayName` is "Unknown field".
- [ ] 2.3 `normalisedForSave` drops blank new website rows but keeps `nil` ones. Unit test.

## 3. Mapper (0.5–1 d)

- [ ] 3.1 `CipherMapper.map`: stop dropping and defaulting (design D1, D3). Read-side tests pass.
- [ ] 3.2 `toRawLogin` / `toRawFields`: encrypt only non-`nil` values; write `rawValue` for the three enums. For a `nil` URI, compute no checksum and send the stored one; pair value-less and nameless entries with stored ones for unknown keys (design D4). Tests 1.2 and 1.3 pass; the `fix-cipher-edit-data-loss` checksum and overlay tests still pass.
- [ ] 3.3 Regression guard: an item with only known values produces the same request body structure (keys, field order and presence) as before.

## 4. Presentation (1 d)

- [ ] 4.1 `CustomFieldsSection` and `CustomFieldsEditSection`: "Unnamed field" label; read-only value for `.unknown` type labelled "Unsupported field type"; "→ Unknown field" for an unknown linked id. VoiceOver labels (§VIII). Tokens from `DesignSystem.swift` only. The label texts are tested as values (a small helper), the rows by build and hand check.
- [ ] 4.2 Login detail skips `nil` URIs; `LoginEditForm` shows them as empty rows with placeholder "No website"; an untouched row saves as `nil` (covered by 1.3 and 2.3).
- [ ] 4.3 Match-type picker shows "Unknown match rule" as a disabled current value; picking a known rule replaces it.
- [ ] 4.4 `VaultRepositoryImpl.matchesSearch`, the favicon lookups and Copy Website skip `nil` URIs. Tests for search.
- [ ] 4.5 Hand check on a build (UI tests only if Christian approves a run): an item with a nameless field, a value-less URI and unknown values (created on the rig through the API) shows as specified in the detail and edit views, and a save keeps them (server record checked).

## 5. Comments and release (0.5 d)

- [ ] 5.1 Fix the comments listed in design.md, Context: `CipherMapper.swift:34` and `:482`, and the type labels in `SyncRepositoryImpl.swift:125`.
- [ ] 5.2 Security review (light): `toRawCipher` still encrypts every non-`nil` sensitive string; no plaintext of nameless fields or `nil` URIs is logged.
- [ ] 5.3 CHANGELOG "Fix": editing an item no longer deletes custom fields without a name or website entries without an address, and no longer changes unknown field types, linked fields or URI match rules. Items already changed by earlier versions can't be repaired.
- [ ] 5.4 Add a note to `macos-autofill-credential-provider` design D4 (on `spec/autofill-passkeys-change-requests`): `nil` URIs and unknown match rules never match.
- [ ] 5.5 `/code-review`, `openspec validate fix-read-mapping-lossless-fields --type change --strict`, `/opsx:verify`.
- [ ] 5.6 Archive the change (at the end of the batch, in PR order).
