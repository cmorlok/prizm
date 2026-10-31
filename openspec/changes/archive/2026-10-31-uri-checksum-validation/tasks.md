# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-cipher-edit-data-loss` (decodes `uriChecksum`, reads keyed items, recomputes
checksums on save), merged.
**Must land before:** `macos-autofill-credential-provider`.

## 1. Known answers and failing tests (0.5 d)

- [x] 1.1 `URIChecksum` tests with the SDK vectors (`login.rs:788-815`):
  - valid: "https://example.com" with `EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk=`
  - invalid: the same URI with `UtSgIv8LYfEdOu7yqjF7qXWhmouYGYC8RSr7/ryZg5Q=`
  - missing checksum
  - empty URI with `47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=`
  - non-base64 checksum
  - non-ASCII URI (UTF-8 bytes)

  Done: `UriChecksumValidationTests` (`testValidChecksum_sdkVector`, `testWrongChecksum_sdkVector`, `testMissingChecksumOrURI_isInvalid`, `testEmptyURI_matchesTheHashOfNothing`, `testNonBase64Checksum_isInvalid`, `testNonASCIIURI_hashesItsUTF8Bytes`); red 20261030T191936Z (compile only: `URIChecksum` did not exist yet). Code review: non-canonical base64 is refused, as by the SDK's STANDARD engine (`testNonCanonicalBase64_isInvalid`; red 20261031T074715Z, green 20261031T074650Z).
- [x] 1.2 Failing mapper tests for a keyed login with four URIs (valid; wrong checksum; no checksum; `uri` nil). Only the first is kept, and `hiddenURICount == 3`. Done: `testKeyedLogin_keepsOnlyTheValidWebsite_andCountsTheOthers`, plus `testChecksumThatDoesNotDecrypt_hidesTheWebsite_notTheItem`; red 20261030T191936Z (compile only).
- [x] 1.3 Failing test: the same four URIs on an *unkeyed* login. All are kept as today (design D1); the `nil` one is subject to `fix-read-mapping-lossless-fields`. Done: `testUnkeyedLogin_keepsEveryWebsite`.

## 2. Implementation (0.5 d)

- [x] 2.1 `URIChecksum.isValid` (CryptoKit SHA-256, constant-time compare) with the §VII security comment (design D2). Done: `Data/Mappers/URIChecksum.swift`; green 20261030T192217Z (1379 unit tests).
- [x] 2.2 `CipherMapper.mapLogin` filters keyed items; `LoginContent.hiddenURICount`; `.error` log with item ID and count only. Done.
- [x] 2.3 Test (design D5): edit a keyed login after a URI was removed. The PUT body contains only the valid URIs, each with a freshly computed checksum, and never the removed URI's checksum. Done: `testEditAfterRemoval_sendsOnlyTheKeptWebsiteWithAFreshChecksum`. Code review: a shown website never takes the stored extras of a hidden one with the same text (`toRawLogin(checksAddresses:)`, `testSave_aHiddenWebsiteGivesNothingToAShownOneWithTheSameText`; red 20261031T074715Z, green 20261031T074650Z).

## 3. Presentation (0.5 d)

- [x] 3.1 Login detail notice row with help text and VoiceOver hint, also when every website was removed (design D4); DesignSystem tokens. Unit test of the notice text; XCUITest of the row with a fixture keyed login. Done: `LoginDetailView` notice row, `HiddenWebsitesNoticeTests`; code review: "every website removed" made testable (`LoginDetailView.showsWebsitesCard`, `testWebsitesCard_isShownWhenEveryWebsiteWasHidden`). XCUITest `VaultBrowserJourneyTests.testHiddenWebsitesNotice_isShownAndReadable` (fixture gamma with one hidden website): passed in the approved full UI run 20261030T205732Z and in the rerun 20261031T082242Z. VoiceOver hand check: Christian, 2026-10-31 (Debug build of the batch-3 integration branch, rig fixture `checksum-032-mvw51f54`): notice and hint read.
- [x] 3.2 Search and favicon lookup see only kept URIs (they already use the Domain list). Regression tests. Done: `testSearchDoesNotFindTheItemThroughAHiddenWebsite`; `testFavoriteAndCopyWebsiteSeeOnlyKeptWebsites` checks `firstAddress`, which the website icon host (`WebsiteIconHost.host(for:)`) and Copy Website read.

## 4. Interop, review, release (0.5 d)

- [x] 4.1 On the rig (Vaultwarden 1.37.4): create a keyed login with two URIs with the official `bw` CLI. Through the API, replace one URI's ciphertext with the other URI's ciphertext from the same item (valid MAC, wrong checksum). Confirm that Prizm hides it and shows the notice, that `bw` hides it too, and that a Prizm edit of that item leaves one URI with a correct checksum on the server. Done, with one difference: the fixture is planted through the API with its own item key (no client writes a wrong checksum), the second website carrying the checksum of another address (same effect: valid MAC, wrong checksum). Live run 20261031T081759Z: `032.4.1.read` PASS (1 shown, 1 hidden), `032.4.1.save` PASS, `032.4.1.api` PASS (server holds only the kept website, checksum valid), `032.4.1.bw` PASS. `bw` on a second fixture never saved by Prizm (`checksum-032-mvw51f54`, 20261031T170329Z) shows only the kept website, so `bw` hides it too. Notice in the app: hand check of 3.1.
- [x] 4.2 Add to `macos-autofill-credential-provider` (design D4/D5 and tasks): depends on `uri-checksum-validation`; the extension decrypt path uses the same mapper; removed URIs never reach `ASCredentialIdentityStore`. Done on the change-request branch `spec/autofill-passkeys-change-requests`, commit 8d8360f3 (design D4/D5, tasks 4.2/5.1).
- [x] 4.3 Confirm that `fix-cipher-edit-data-loss` design D3 ("recompute every checksum on every save") is in the base branch (`toRawLogin`). Done: `CipherMapper.toRawLogin` encrypts `uriChecksumPlaintext(address)` for every website with an address.
- [x] 4.4 Mandatory security review: predicate equality with the SDK, constant-time compare, no URI in logs. Done: fresh reviewer, 2026-10-31, read-only. No high, medium or low defect in the change. Predicate as in the design (keyed items only; missing, non-base64 and non-canonical checksums invalid; SHA-256 of the UTF-8 bytes); constant-time compare (`URIChecksum.swift`); logs carry the item ID and count only; the save path never re-sends a hidden website or pairs its extras. One informational note, older than this change: a keyed item whose website address does not decrypt is still dropped as a whole at sync (`mapLogin` decrypts the address strictly). The design goal now says "same decision for every decryptable input"; hiding and counting such an address is a follow-up (design, Review).
- [x] 4.5 CHANGELOG "Security": website entries of items with their own key are now verified against their integrity checksum, as in official Bitwarden apps; entries that fail are hidden. Done.
- [x] 4.6 `openspec validate uri-checksum-validation --type change --strict`. Done before the archive.
