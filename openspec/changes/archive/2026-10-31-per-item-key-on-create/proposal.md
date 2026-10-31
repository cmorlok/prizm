# Proposal

## Why

**Criticality:** P3 (Low: parity with official clients; no data loss)
**Findings:** plan review decision C (`.planning/research/source-review/SUMMARY.md`)

Bitwarden items can carry their own encryption key ("cipher key encryption"): a random key, wrapped
with the vault key or the organization key, that encrypts all of the item's fields and attachment
keys. Official clients now give every item they create such a key:

- The Bitwarden SDK removed the `cipher-key-encryption` flag on 2026-10-05 (sdk-internal commit
  `095bfda`, "[PM-41071] Remove cipher key encryption flag"). Since then every item the SDK
  encrypts gets its own key (`CipherView::load_cipher_key_slot`,
  `crates/bitwarden-vault/src/cipher/cipher.rs`). Web, browser extension, desktop and CLI pick this
  up as they move to SDK builds after that commit.
- The iOS app has always enabled it unconditionally (`ClientService.swift`,
  `enableCipherKeyEncryption: true`).

Prizm creates items without their own key. `VaultRepositoryImpl.create` encrypts the fields with the
vault key or the org key, and `CipherMapper.toNewRawCipher` sends `key: nil`. Both servers and all
clients still accept and read these items, so nothing breaks. Still, **Prizm writes a format
official clients no longer produce.** Items created in Prizm stay in the older format until an
official client edits them, at which point the SDK adds a key on its own.

The key cache is ready for it: since `fix-org-attachment-key`, `create()` records the new item's key
source in `VaultKeyCache` from the server's answer, and `VaultKeyServiceImpl` no longer falls back to
the vault key, so an attachment added before the next sync already uses the right key.

`fix-cipher-edit-data-loss` makes Prizm read and edit items that have their own key. Creating them
too is the remaining step to parity on the write side. That fix is deliberately limited to
preserving data, so key generation is left to this change.

## What Changes

- **New items get their own key.** `create()` generates a random 64-byte key, wraps it with the vault
  key (personal item) or the org key (org item), encrypts every field with it, and sends the wrapped
  key as `key` in the create request.
- **The new key is usable immediately.** The existing create path records the item's key source from
  the server's answer, which now carries the item's own key, so attachments added before the next
  sync use it. The answer's `key` must unwrap to the bytes Prizm generated.
- **Fail closed.** If key generation or wrapping fails, the save fails with an error. Prizm never
  falls back to creating the item without a key.

## Capabilities

### New Capabilities
- `cipher-key-on-create`: items created in Prizm carry their own encryption key, as items created
  by official clients do.

### Modified Capabilities
_None._ The create UI is unchanged.

## Non-Goals

- **Adding a key to existing items on edit.** The SDK does this whenever it edits an item without
  one. In Prizm it would mean re-encrypting fields that `fix-cipher-edit-data-loss` deliberately
  keeps as opaque ciphertext (passkeys, password history), and re-wrapping attachment keys. Legacy
  attachments without their own key need extra handling (the SDK refuses some operations on them:
  `CipherError::AttachmentsWithoutKeys`). Possible follow-up change.
- Re-wrapping or rotating existing item keys.
- Moving items between personal vault and organization (Prizm has no share flow).
- Accounts on the newer (v2, COSE) user-key format. Prizm supports type-2 EncStrings
  (AES-256-CBC + HMAC-SHA256) only, today and after this change.

## Dependencies

- **Hard:** `fix-org-attachment-key` (merged). It replaced the cache-miss fallback in
  `VaultKeyServiceImpl` and records the key source on create. This change only adds the item's own
  key to that path; design D4 here is reduced to using it.
- **Hard:** `fix-cipher-edit-data-loss` (merged). Prizm must be able to read items with their own key
  (its design D0) and edit them with the effective key (D2) before it creates them. Otherwise Prizm
  could not edit the items it creates. It also provides `encryptedFor`, which Vaultwarden 1.37.4
  requires on create.
- `fix-cipher-edit-data-loss` creates new items without a per-item key, as today (its proposal,
  Non-Goals), and its design D2 names this change as the one that supersedes that rule. That remains
  true for that fix, and this change supersedes it.

## Impact

- **Data only:**
  - `Data/Crypto`: the existing 64-byte key generation (`generateAttachmentKey`) becomes
    `generateSymmetricKey()`, shared by attachment and item keys. No new algorithm.
  - `CipherMapper.toNewKeyedRawCipher`: wraps the item key and encrypts every field with it.
  - `VaultRepositoryImpl.create`: generate, wrap, encrypt, send; the existing cache write stays.
- **Domain / Presentation:** none.
- **No new dependencies.**
- **Security review required** (§III: key generation and key selection on the write path).

## Estimate

Ideal engineer-days, TDD included, assuming `fix-cipher-edit-data-loss` has landed.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm wire details against the SDK and both servers | 0.5 d |
| 2 | Key generation and wrapping helpers, known-answer tests | 0.5 d |
| 3 | `create()` with own key, personal and org | 0.5–1 d |
| 4 | Cache on create; attachment on a new item before sync | 0.5 d |
| 5 | Interop check with an official client, security review, CHANGELOG | 0.5 d |
| **Total** | | **2.5–3 d** |
