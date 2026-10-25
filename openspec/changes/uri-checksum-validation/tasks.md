# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-cipher-edit-data-loss` (decodes `uriChecksum`, reads keyed items, recomputes
checksums on save), merged.
**Must land before:** `macos-autofill-credential-provider`.

## 1. Known answers and failing tests (0.5 d)

- [ ] 1.1 `URIChecksum` tests with the SDK vectors (`login.rs:788-815`):
  - valid: "https://example.com" with `EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk=`
  - invalid: the same URI with `UtSgIv8LYfEdOu7yqjF7qXWhmouYGYC8RSr7/ryZg5Q=`
  - missing checksum
  - empty URI with `47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=`
  - non-base64 checksum
  - non-ASCII URI (UTF-8 bytes)
- [ ] 1.2 Failing mapper tests for a keyed login with four URIs (valid; wrong checksum; no checksum; `uri` nil). Only the first is kept, and `hiddenURICount == 3`.
- [ ] 1.3 Failing test: the same four URIs on an *unkeyed* login. All are kept as today (design D1); the `nil` one is subject to `fix-read-mapping-lossless-fields`.

## 2. Implementation (0.5 d)

- [ ] 2.1 `URIChecksum.isValid` (CryptoKit SHA-256, constant-time compare) with the §VII security comment (design D2).
- [ ] 2.2 `CipherMapper.mapLogin` filters keyed items; `LoginContent.hiddenURICount`; `.error` log with item ID and count only.
- [ ] 2.3 Test (design D5): edit a keyed login after a URI was removed. The PUT body contains only the valid URIs, each with a freshly computed checksum, and never the removed URI's checksum.

## 3. Presentation (0.5 d)

- [ ] 3.1 Login detail notice row with help text and VoiceOver hint, also when every website was removed (design D4); DesignSystem tokens. Unit test of the notice text; XCUITest of the row with a fixture keyed login.
- [ ] 3.2 Search and favicon lookup see only kept URIs (they already use the Domain list). Regression tests.

## 4. Interop, review, release (0.5 d)

- [ ] 4.1 On the rig (Vaultwarden 1.37.4): create a keyed login with two URIs with the official `bw` CLI. Through the API, replace one URI's ciphertext with the other URI's ciphertext from the same item (valid MAC, wrong checksum). Confirm that Prizm hides it and shows the notice, that `bw` hides it too, and that a Prizm edit of that item leaves one URI with a correct checksum on the server.
- [ ] 4.2 Add to `macos-autofill-credential-provider` (design D4/D5 and tasks): depends on `uri-checksum-validation`; the extension decrypt path uses the same mapper; removed URIs never reach `ASCredentialIdentityStore`.
- [ ] 4.3 Confirm that `fix-cipher-edit-data-loss` design D3 ("recompute every checksum on every save") is in the base branch (`toRawLogin`).
- [ ] 4.4 Mandatory security review: predicate equality with the SDK, constant-time compare, no URI in logs.
- [ ] 4.5 CHANGELOG "Security": website entries of items with their own key are now verified against their integrity checksum, as in official Bitwarden apps; entries that fail are hidden.
- [ ] 4.6 `openspec validate uri-checksum-validation --type change --strict`.
