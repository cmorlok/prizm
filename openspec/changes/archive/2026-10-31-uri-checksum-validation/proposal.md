# Proposal

## Why

**Criticality:** P3 (Low today). It becomes **P1 before AutoFill ships**: once Prizm fills
credentials into websites, an unchecked URI is a way to send credentials to the wrong site.
**Findings:** S-11 (`03-sync-read.md`)

Every login URI that a current Bitwarden client writes carries a `uriChecksum`: the encrypted
base64 SHA-256 of the URI. The Bitwarden SDK checks it when it decrypts an item that has its own
key. A URI whose checksum is missing or wrong is removed. This defends against a server that
inserts or swaps a URI in an item. Without the check, such a server could make a login match an
attacker's site, and an autofill client would offer the credentials there.

Prizm does not decode `uriChecksum` at all (`Prizm/Data/Network/Models/RawCipher.swift:116-120`).
It shows every URI it can decrypt (`CipherMapper.swift:195-200`).

Today the impact is low:
- Prizm only shows URIs and opens them on request; it does not autofill.
- Prizm can't yet read items that have their own key at all. The read path decrypts their fields
  with the vault key. `fix-cipher-edit-data-loss` fixes that (its design D0).

`macos-autofill-credential-provider` will match URIs against websites and register them with the
system credential store. From that point, a URI that the server could have planted is a real risk.

**Origin of the current behaviour:** accidental. `uriChecksum` was never modelled (`fd32450`,
2026-03-16). `fix-cipher-edit-data-loss` adds the field and recomputes it on every save and
create, but does not check it on read.

## What Changes

- **Check URI checksums on read, as the SDK does.** For an item that has its own key, each URI is
  kept only if it has a value and a checksum, and the checksum decrypts to the base64 SHA-256 of
  that value. Other URIs are removed from the decrypted item.
- **Removed URIs stay removed.** They are not shown, not searched, not used for icons, and not
  offered to AutoFill. The next save of the item no longer contains them, as with official clients.
- **Visible notice.** The item detail says "1 website was hidden because it failed an integrity
  check." The sync log records the count. Neither shows the URI.
- **Items without their own key are not checked,** as in the SDK. Prizm has no V2 (COSE) account
  support, so the SDK's second condition (V2 accounts) can't apply yet; it is recorded for later.

## Capabilities

### New Capabilities
- `uri-checksum-validation`: login URIs of keyed items are verified against their checksum before
  any use.

### Modified Capabilities
_None._

## Non-Goals

- Computing checksums on save. That is `fix-cipher-edit-data-loss` (its design D3:
  recompute for every URI on every save and create).
- Checking items without their own key. The SDK doesn't, for compatibility with old data
  (`cipher.rs:812-818`).
- V2 (COSE) accounts. Prizm doesn't support them (audit 02 C-08).

## Dependencies

- **Hard:** `fix-cipher-edit-data-loss` (merged).
  - It decodes `uriChecksum`.
  - It makes keyed items readable (its design D0). Without that, there are no keyed items to check.
  - It recomputes every checksum on every save and create (its design D3). With this change, only
    valid URIs reach the save path, so the recompute never re-signs a URI that failed the check.
- **Soft:** `fix-read-mapping-lossless-fields` (merged). It keeps URIs whose value is `nil`. For keyed items,
  this change removes them, because the SDK treats a missing value as an invalid checksum
  (`login.rs:58-61`). For unkeyed items they are kept.
- **This change is a hard dependency of `macos-autofill-credential-provider`.** AutoFill must not
  ship before it. The AutoFill extension's own decrypt path (its encrypted vault cache) must apply
  the same check, by using the same mapper.

## Impact

- **Data:**
  - `CipherMapper.mapLogin`: checksum verification for keyed items
  - a small `URIChecksum` helper (CryptoKit `SHA256`, constant-time compare)
  - removed-URI count on the mapped item
- **Domain:** `LoginContent.hiddenURICount: Int` (Foundation-only).
- **Presentation:**
  - one notice row in the login detail, with a VoiceOver label
  - DesignSystem tokens only
- **No new dependencies.** CryptoKit is already used in the Data layer.
- **Security review:** yes. Integrity check on vault data (§III), hashing, constant-time compare.

## Estimate

Ideal engineer-days, TDD included, assuming `fix-cipher-edit-data-loss` has landed.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Known-answer tests from the SDK; failing mapper tests | 0.5 d |
| 2 | Checksum helper and mapper filter | 0.5 d |
| 3 | Notice in the detail pane, VoiceOver | 0.5 d |
| 4 | Interop check with an official client, security review, CHANGELOG | 0.5 d |
| **Total** | | **2 d** |
