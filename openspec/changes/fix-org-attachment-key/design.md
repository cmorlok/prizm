# Design

## Context

**Official rule.** Sources at HEAD 2026-10-23; the SDK references were checked again at
sdk-internal `c1c9b9a5` (2026-10-29) and had not moved.

- SDK `crates/bitwarden-vault/src/cipher/cipher.rs:835-844` (`decrypt_cipher_key`): with an item
  key, unwrap it with the owning key; without one, use the owning key itself.
- The owning key is the org key for an org item and the user key otherwise
  (`cipher.rs:1432-1437`, `key_identifier`).
- New attachment material (attachment key and file name) is built under that key
  (`cipher.rs:854-867`, `make_attachment_material`).
- TS legacy path: `clients/libs/common/src/vault/services/cipher.service.ts:860-873` picks
  `orgKeys[cipher.organizationId]` for an org item and the user key otherwise, then the item key
  if present. Download uses the same rule (`cipher.service.ts:1328-1340`).

**Updating attachment metadata without re-upload.** Both servers accept `attachments2`
(`{id: {fileName, key}}`) on `PUT /api/ciphers/{id}` and overwrite each attachment's file name and
key: Vaultwarden 1.37.4 `src/api/core/ciphers.rs:516-538`, Bitwarden server
`src/Api/Vault/Models/Request/CipherRequestModel.cs:259-284`. Official clients send it on every
update (`clients/libs/common/src/vault/models/request/cipher.request.ts:357-367`).

**Prizm today.**
- `VaultKeyServiceImpl.swift:43-65`: cache hit → cached key; miss → vault key. No org lookup.
- `VaultKeyCache.swift`: `[cipherId: Data]`, wholesale `populate`, `clear` zeroes.
- `PrizmCryptoService.swift:302-306` and `SyncRepositoryImpl.swift:251`: an entry only when
  `cipher.key != nil`. `CipherMapper.map` already returns the correct effective key for every item
  (`CipherMapper.swift:124-188`, `effectiveKeys` at 225); it is discarded for keyless items.
- `SyncRepositoryImpl.swift:198` swaps all org keys into `OrgKeyCache` in one step
  (`replaceAll`, from `fix-org-key-required-on-write`), so the cache is never empty during a sync.
- `CipherMapper.swift:161-169`: an attachment whose file name doesn't decrypt is dropped with an
  error log. This is how wrongly keyed attachments disappear after sync.
- `AppContainer.swift:113`: `VaultKeyServiceImpl(cache:crypto:)` has no access to `OrgKeyCache`.

## Goals / Non-Goals

**Goals**
- The attachment key for an item is always the key official clients would use.
- No silent fallback to a different key. A missing key is an error the user sees.
- Attachments already saved with the wrong key become visible again and can be repaired.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Cache the key source, not copies of the key

```swift
enum CipherKeySource { case itemKey(Data), organization(orgId: String), personal }
```

`VaultKeyCache` maps cipher ID → `CipherKeySource`. `VaultKeyServiceImpl.cipherKey(for:)`:
1. `.itemKey(k)` → `k`.
2. `.organization(id)` → `OrgKeyCache` key for `id`, else throw `VaultError.organizationKeyUnavailable`.
3. `.personal` → vault key from `crypto.currentKeys()` (locked → `vaultLocked`, as today).
4. No entry → throw `VaultError.cipherKeyUnavailable`. Log at `.error` with the cipher ID prefix.

**Why.** Org and vault keys stay in one place each. When `OrgKeyCache` is refilled, every org item
resolves to the current key without touching `VaultKeyCache`. `clear()` still zeroes item keys.

**Rejected alternative:** store the effective 64-byte key for every item. Simple, but it puts one
copy of the org or vault key per item into the cache, and those copies go stale when the org cache
changes.

**Rejected alternative:** on a cache miss, look up the item's `organizationId` in
`VaultRepository`. It couples two repositories, and an unknown item still needs a failure path.

### D2. Record a source for every item on sync and on create

- `decryptList` and the org pass in `SyncRepositoryImpl` add an entry for every successfully mapped
  item: `.itemKey` when `raw.key != nil`, else `.organization(orgId)` or `.personal`.
- `VaultRepositoryImpl.create` adds `.organization(orgId)` or `.personal` for the new ID after a
  successful response. `per-item-key-on-create` later changes this to `.itemKey`.
- `populate` is one wholesale replace after the org pass (review 2026-10-30: an earlier version
  replaced the cache with the personal sources first, so org items still listed from the previous
  sync had no source while the org pass ran). An entry added by `create` while a sync runs is lost
  when the item is not in that sync's response (created after the sync request); the item leaves
  the list with that sync too, so the two stay consistent, and the next sync brings both back.
- `create` records only if no lock cleared the cache since its request began
  (`VaultKeyCache.generation`), so a source, and later an item key, never outlives the session.

### D3. Find attachments that were wrapped with the personal key

In `CipherMapper`, for an org item **without** its own key: if an attachment's file name fails to
decrypt with the org key, try the vault key. If the MAC verifies:
- keep the attachment with `wrappedWithPersonalKey = true`,
- on download, `DownloadAttachmentUseCaseImpl` sees the flag and asks `VaultKeyService` for the
  personal key (new `personalKey()`), so the attachment key is unwrapped with the key it was
  actually wrapped with. The choice stays in Data; Presentation only sees the flag,
- log at `.info` (attachment ID only).

If both fail, keep today's behaviour (log and drop). Personal items and keyed org items are not
affected: Prizm always used the right key for them.

Security note: the extra attempt uses a key the user already holds, and the MAC is checked before
any decryption, so it can't produce wrong plaintext. It only runs for the narrow case above.

### D4. Repair by conversion, not by re-wrapping

Every wrongly keyed attachment was uploaded by Prizm, so it is also in Prizm's old file layout
(`fix-attachment-file-format`, D2). Official clients can't read it even with the right key. The
repair is therefore the conversion in that change: download (attachment key unwrapped with the
vault key, D3), re-upload under the org key in the official layout, delete the old one. The row
shows "Only you can open this file" and the "Convert" action from that change.

**Rejected alternative:** re-wrap the attachment key and file name with the org key and send them
as `attachments2` on `PUT /api/ciphers/{id}`. Both servers support it (Context). It moves no file
data, but it leaves the file in the old layout, and it needs a full item PUT, which is only safe
after `fix-cipher-edit-data-loss`.

### D5. User-facing errors

- `cipherKeyUnavailable`: "Prizm doesn't have the key for this item yet. Sync and try again."
- `organizationKeyUnavailable` (exists since `fix-org-key-required-on-write`, which raises it when
  a save finds no org key): "This item's organization can't be accessed right now. Lock and unlock
  Prizm, then try again." Reused, so a missing org key reads the same for saves and attachments.

Both are shown inline in the attachment sheet or row. Neither falls back to another key.

## Risks / Trade-offs

- **[Medium] An item missing from the cache** now fails instead of "working" with the vault key.
  For personal items that path was correct before. → D2 records every item on sync and on create;
  tests cover create → attach without sync for personal and org items.
- **[Low] Extra decryption attempt** on keyless org attachments that fail. → Only after a failure;
  MAC-checked; no plaintext produced on mismatch.
- **[Low] Org key rotation** between sync and use. → Resolution reads `OrgKeyCache` at use time
  (D1), so it uses the key from the latest sync.
- **[Low] Other org members can't open affected files until the uploader converts them.** Prizm
  can't tell them; they only see a file they can't open. → The CHANGELOG entry (task 5.3) names
  the problem, and conversion (D4) fixes it for everyone.

## Open Questions

1. How many users have wrongly keyed org attachments? Unknown. The detection in D3 logs a count
   per sync, so the maintainer can ask users to report it.
