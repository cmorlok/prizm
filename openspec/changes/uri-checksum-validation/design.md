# Design

## Context

**Official behaviour.** Source: `sdk-internal` at 2026-10-23, `crates/bitwarden-vault/src/cipher/`.

- **When the check runs.**
  - After lenient decryption: `if view.key.is_some() || ctx.get_security_state_version() >=
    MINIMUM_ENFORCE_ICON_URI_HASH_VERSION { view.remove_invalid_checksums(); }`
    (`cipher.rs:812-818`). The comment reads "For compatibility we only remove URLs with invalid
    checksums if the cipher has a key or the user is on Crypto V2".
  - The same check runs on the restricted-view path (`cipher.rs:1563-1568`, "guards against a
    tampering server") and on the list-view path (`cipher.rs:1826-1831`).
  - `MINIMUM_ENFORCE_ICON_URI_HASH_VERSION = 2`
    (`bitwarden-core/src/key_management/security_state.rs:33`).
- **What it removes.** `remove_invalid_checksums` keeps only URIs where `is_checksum_valid()` holds
  (`cipher.rs:959-963`). `is_checksum_valid` (`login.rs:58-73`) returns false when any of these
  hold:
  - `uri` is `None`
  - `uri_checksum` is `None`
  - the checksum is not valid base64
  - the decoded bytes differ from `SHA-256(uri.as_bytes())`

  The comparison is constant-time (`subtle::ConstantTimeEq`).
- **How the checksum is made.** `generate_checksum`: base64 (standard, padded) of SHA-256 over the
  exact UTF-8 bytes of the URI, encrypted as an EncString with the cipher key. It is skipped when
  `uri` is `None` (`login.rs:75-82`), and runs on every encrypt (`cipher.rs:701`).
- **Known-answer vectors.**
  - `"https://example.com"` → `EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk=` (`login.rs:792`;
    re-checked with `openssl dgst -sha256`).
  - `""` → `47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=` (re-checked with `openssl`).
  - The invalid and missing cases are `login.rs:798-815`.
- **Consequence in official clients.** A removed URI is absent from the view. When the user saves
  the item, the SDK encrypts the view, so the removed URI is deleted on the server. The earlier plan
  review confirmed this ("Their next save deletes the URI").

**Prizm today** (`origin/develop` beb861ff, after `fix-cipher-edit-data-loss` and
`fix-read-mapping-lossless-fields`).
- `RawURI` decodes `uriChecksum` and keeps unknown keys (`Prizm/Data/Network/Models/RawCipher.swift`).
- `CipherMapper.map` resolves the item's own key first (`effectiveKeys(for:activeKeys:)`) and reads
  every field under it.
- `CipherMapper.mapLogin` decrypts every URI with a value and keeps value-less URIs as `nil`; the
  checksum is never decrypted or checked.
- `toRawLogin` computes a fresh checksum for every address on every save and create, and sends a
  value-less website back with its stored checksum as received.
- `LoginContent.addressedURIs` (detail view) and `firstAddress` (favicon, Copy Website) read the
  Domain list, so whatever `mapLogin` drops never reaches them.

## Goals / Non-Goals

**Goals**
- No URI that fails the SDK's check is ever shown, searched, used for icons or offered to AutoFill.
- Byte-for-byte the same decision as the SDK for every input.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Same gate as the SDK, minus V2

- Check when `raw.key != nil`.
- A value-less URI of a keyed item is removed too: the SDK's predicate is false without a value
  (`login.rs:58-61`), and its `generate_checksum` never writes a checksum for one. Unkeyed items
  keep value-less URIs as `fix-read-mapping-lossless-fields` defines.
- The V2 condition is recorded as a `// TODO` with the SDK reference. It becomes relevant only when
  Prizm supports V2 accounts.
- Unkeyed items are not checked.

**Rejected alternative:** check every item. Items without their own key, created before checksums
existed, would lose their URIs. The SDK avoids this on purpose.

### D2. Same predicate as the SDK

`URIChecksum.isValid(uri:checksumPlaintext:)`:
1. Both values present.
2. Base64-decode the checksum (standard alphabet, padding required).
3. Compute `SHA256.hash(data: Data(uri.utf8))` with CryptoKit.
4. Compare with a constant-time loop.

The checksum EncString is decrypted with the item's effective key, like the URI. If decrypting the
checksum fails, the URI is invalid. The URI is not decrypted again.

Security comment (§VII):
- **Goal:** stop a malicious server from adding or swapping login URIs.
- **Algorithm:** SHA-256 per FIPS 180-4, base64 per RFC 4648 §4.
- **Reference:** SDK `login.rs:58-73`.
- **Deviation:** none.
- **Not done:** no check for unkeyed items (D1).

### D3. Remove, don't keep hidden

Invalid URIs are dropped from the Domain item, as in the SDK. `LoginContent.hiddenURICount`
records how many. The next save therefore deletes them on the server, which is what the next
official save would do too.

**Rejected alternative:** keep them hidden in the Data layer and send them back on save. That keeps
an attacker-planted URI in the vault indefinitely. It would also require re-sending its old
checksum, which conflicts with the recompute rule of `fix-cipher-edit-data-loss`.

### D4. Notice to the user

- If `hiddenURICount > 0`, the login detail shows one secondary-style row: "N website(s) hidden
  because they failed an integrity check."
- The row's help tooltip and VoiceOver hint explain that the server or another app changed the
  entry, and that the next save of the item removes it from the server. No separate info button
  and no "Remove now" action (Christian, 2026-10-30): a save without a user edit has no intent
  behind it, and the hidden URI is never used meanwhile.
- The row sits at the end of the Websites card. When every website was removed, the card shows the
  notice row alone, so the notice is never lost with the card.
- VoiceOver reads the row text.
- `CipherMapper` logs `.error` with the item ID and count, never the URI.

This goes beyond the SDK, which removes silently. It follows Constitution §V (no silent failures).

### D5. Ordering with the save path

Read-time validation runs before the Domain item exists, so `fix-cipher-edit-data-loss` only ever
sees valid URIs. Its recompute then gives every saved URI a fresh, correct checksum. It builds the
websites from the draft and takes only the unknown keys of a stored website with the same text,
never its checksum (its design D2 and D3), so the original checksum of a URI that this change
removed is never re-attached. A test covers that.

### D6. AutoFill

`macos-autofill-credential-provider` builds its identity store and its matching from the same
`CipherMapper` output. Its extension-side decrypt path must also go through `CipherMapper` (or the
same helper). Recorded as a requirement there (task 4.2).

## Risks / Trade-offs

- **[Low] Legitimate URIs removed.** It would take a keyed item with a URI whose checksum is
  missing or wrong without tampering. That happens only with buggy clients. Official clients remove
  the same URIs, so Prizm is not worse.
- **[Low] Prizm-written data before this change.** Prizm saved without checksums before
  `fix-cipher-edit-data-loss`, but it couldn't save keyed items correctly anyway.

## Open Questions

None. Closed 2026-10-30 (Christian): no "Remove now" action; the notice waits for the next edit (D4).
