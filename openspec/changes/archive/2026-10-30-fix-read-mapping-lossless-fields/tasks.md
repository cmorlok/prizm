# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Failing tests (0.5 d)

- [x] 1.1 Add a `RawCipher` fixture: a login with a custom field `name: null`, a URI `uri: null` with `match: 3`, a field with `type: 9`, a linked field with `linkedId: 999`, and a URI with `match: 7`. Done: `LosslessFieldsMapperTests.storedRecord()`, built as JSON; the nameless field and the value-less URI also carry an unknown key.
- [x] 1.2 Failing test: map the fixture, change only the username, run `toRawCipher(_:overlaying:...)`. Assert that:
  - the nameless field is present with `name == nil`
  - the `nil` URI is present with `uri == nil`, its original `match` and its stored `uriChecksum`
  - `type == 9`, `linkedId == 999` and `match == 7` are unchanged
  - element order is unchanged
  - unknown JSON keys of the nameless field and the value-less URI are carried over (D4)
  Done: `testSave_sendsNamelessFieldWithNullName`, `testSave_keepsUnknownFieldTypeAndLinkedId`, `testSave_sendsValueLessWebsiteWithNullUriAndStoredChecksum`, `testSave_keepsUnknownMatchRuleAndOrder`. Red `20261030T081404Z` (compile: optional name/uri and `unknown` cases missing). The live rig run showed that an omitted key stays absent on Vaultwarden, so the tests now also require an explicit `null`: red `20261030T111554Z` (the two null tests failed), green `20261030T111626Z` (1113 unit tests).
- [x] 1.3 Failing test: the same fixture through `DraftVaultItem`, `normalisedForSave` and back to `VaultItem` (the post-save path in `VaultRepositoryImpl.update`) keeps all five values. Done: `testSavedRequestMapsBackToTheSameValues` and `LosslessFieldTypesTests.testDraftRoundTrip_keepsNilNameAndNilUri`; red `20261030T081404Z`.

## 2. Domain types (0.5 d)

- [x] 2.1 `CustomField.name: String?`, `LoginURI.uri: String?`, plus the `DraftCustomField` and `DraftLoginURI` mirrors. `DraftLoginURI` remembers a row read without a value; while that row is empty its `uri` stays `nil` (D2). `DraftLoginURI.init()` for a new row keeps today's `""` default (W-17 is out of scope). Done: `DraftLoginURI.readWithoutValue` and `text`; tests `testValueLessWebsite_staysNilWhenTypedIntoAndCleared`, `testNewWebsiteRow_isEmptyStringNotNil`. Green `20261030T081848Z` (1113).
- [x] 2.2 `CustomFieldType`, `LinkedFieldId`, `URIMatchType`: add `unknown(Int)` with a hand-written `RawRepresentable` whose `init(rawValue:)` never fails. Unit tests: every known raw value round-trips; unknown values round-trip; `LinkedFieldId.unknown.displayName` is "Unknown field". Done: `LosslessFieldTypesTests` (three round-trip tests) and `CustomFieldLabelTests.testUnknownLinkedTarget_isUnknownField`. After review, each `unknown` case says it is built by `init(rawValue:)` only.
- [x] 2.3 `normalisedForSave` drops blank new website rows but keeps `nil` ones. Unit test. Done: `testNormalisedForSave_keepsValueLessWebsiteDropsBlankNewRow`.

## 3. Mapper (0.5–1 d)

- [x] 3.1 `CipherMapper.map`: stop dropping and defaulting (design D1, D3). Read-side tests pass. Done: `mapLogin` and `mapFields` use `map`, not `compactMap`; `testRead_keepsNamelessFieldValueLessWebsiteAndUnknownValues`. Live rig run `20261030T113852Z`: Prizm maps all five values of the planted item (`prizm 021.4.5.read`).
- [x] 3.2 `toRawLogin` / `toRawFields`: encrypt only non-`nil` values; write `rawValue` for the three enums. For a `nil` URI, compute no checksum and send the stored one; pair value-less and nameless entries with stored ones for unknown keys (design D4). Tests 1.2 and 1.3 pass; the `fix-cipher-edit-data-loss` checksum and overlay tests still pass. Done: `RawURI` and `RawField` write `uri: null` and `name: null` explicitly (`WireWriter.putOrNull`); `EditOverlayTests` now expect the nameless field to be sent with its keys. Green `20261030T111626Z` (1113, 0 failures). After the squash every commit passes on its own: fix commit `20261030T133659Z`, docs commit `20261030T133716Z` (1113 each, 0 failures).
- [x] 3.3 Regression guard: an item with only known values produces the same request body structure (keys, field order and presence) as before. Done: `testKnownValuesOnly_requestStructureUnchanged` (create path; the update path is covered by `EditOverlayTests`). It checks keys and presence; JSON key order is not observable through `JSONSerialization`.

## 4. Presentation (1 d)

- [x] 4.1 `CustomFieldsSection` and `CustomFieldsEditSection`: "Unnamed field" label; read-only value for `.unknown` type labelled "Unsupported field type"; "→ Unknown field" for an unknown linked id. VoiceOver labels (§VIII). Tokens from `DesignSystem.swift` only. The label texts are tested as values (a small helper), the rows by build and hand check. Code and label tests done (`CustomFieldLabelTests`, build green `20261030T081848Z`); the hand check of the rows (and VoiceOver) was part of 4.5. Visual and VoiceOver check of the rows: skipped by Christian's decision (2026-10-30); the label texts are unit-tested and the data is checked on the rig.
- [x] 4.2 Login detail skips `nil` URIs; `LoginEditForm` shows them as empty rows with placeholder "No website"; an untouched row saves as `nil` (covered by 1.3 and 2.3). Done: `LoginContent.addressedURIs` in `LoginDetailView`; `EditFieldRow(prompt:)` with "No website" for a row read without a value; save behaviour covered by 1.3 and 2.3. The on-screen look is part of the 4.5 hand check.
- [x] 4.3 Match-type picker shows "Unknown match rule" as a disabled current value; picking a known rule replaces it. Code done (`.selectionDisabled()` entry in `URIEditRow`; `testUnknownMatchRule_isNamedButNeverOffered`). Not checked on screen: Christian skipped the visual check (2026-10-30).
- [x] 4.4 `VaultRepositoryImpl.matchesSearch`, the favicon lookups and Copy Website skip `nil` URIs. Tests for search. Done: `testSearch_skipsValueLessWebsite`, `testLaunchPolicy_valueLessWebsiteHasNoURL`; favicons (`ItemRowView`, `ItemDetailView`, `VerificationCodesListView`) and Copy Website (`PrizmApp`) use `LoginContent.firstAddress` (code only).
- [x] 4.5 Hand check on a build (UI tests only if Christian approves a run): an item with a nameless field, a value-less URI and unknown values (created on the rig through the API) shows as specified in the detail and edit views, and a save keeps them (server record checked). Save part done: live rig run `20261030T113852Z` on Vaultwarden 1.37.4: the planted item is stored as planted (`setup.021`), Prizm maps all five values (`prizm 021.4.5.read`), edits the notes and saves (`prizm 021.4.5.save`), and the server record afterwards still has the nameless field, the type-9 field, `linkedId` 999, the value-less URI and match 7, with Prizm's notes edit (`021.4.5.server`). The visual and VoiceOver check of the detail and edit views was skipped by Christian's decision (2026-10-30): the reviewer suggested it, the data path is checked end to end.

## 5. Comments and release (0.5 d)

- [x] 5.1 Fix the comments listed in design.md, Context: `CipherMapper.swift:34` and `:482`, and the type labels in `SyncRepositoryImpl.swift:125`. Done: commit "docs(vault): correct the mapper's org cipher comments and the sync log type labels"; after review the debug label `org(skipped)=` is `org=` as well.
- [x] 5.2 Security review (light): `toRawCipher` still encrypts every non-`nil` sensitive string; no plaintext of nameless fields or `nil` URIs is logged. Done 2026-10-30: design.md, "Review", "Security".
- [x] 5.3 CHANGELOG "Fix": editing an item no longer deletes custom fields without a name or website entries without an address, and no longer changes unknown field types, linked fields or URI match rules. Items already changed by earlier versions can't be repaired. Done: "Fix: editing an item no longer deletes custom fields without a name or websites without an address, and no longer changes field types, linked fields or website match rules that Prizm does not know. Prizm shows them as "Unnamed field", "Unsupported field type" (read-only, hidden like a password), "Unknown field" and "Unknown match rule"; a website without an address appears only in the edit sheet, as an empty row. Items that earlier versions already changed can't be repaired."
- [x] 5.4 Add a note to `macos-autofill-credential-provider` design D4 (on `spec/autofill-passkeys-change-requests`): `nil` URIs and unknown match rules never match. Done: 07246b47 on `spec/autofill-passkeys-change-requests`.
- [x] 5.5 `/code-review`, `openspec validate fix-read-mapping-lossless-fields --type change --strict`, `/opsx:verify`. Done 2026-10-30: independent review (design.md "Review"); valid; `/opsx:verify`: no critical issues; the warnings are the skipped visual checks (4.1, 4.3, 4.5).
- [x] 5.6 Archive the change (at the end of the batch, in PR order).
