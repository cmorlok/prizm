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

## Review

Independent review on 2026-10-30 (a fresh reviewer, diff fix/026..fix/027, read only): no
blockers, three should-fix findings and four nits. Fixes: red `20261030T131144Z` (compile), green
`20261030T131237Z` (1131 unit tests).

- Fixed (S1): org items had no key source in the middle of every sync. The cache was replaced
  with the personal sources first and got the org sources only after the org pass, so an
  attachment on an org item failed with "Sync and try again" while a sync ran. The cache is now
  replaced once, after the org pass (D2).
- Fixed (S2): a source recorded by `create` could outlive a lock, because the lock could clear
  the cache before the record arrived. `create` now records only if no lock cleared the cache
  since its request began (`VaultKeyCache.generation`). This matters once `per-item-key-on-create`
  records item keys here. Test `testCreateFinishingAfterALock_recordsNoKeySource`.
- Fixed (S3): the new `vaultKeyCache` parameter of `VaultRepositoryImpl` had a default, so a
  caller could record into a private cache. It is required now, like its siblings.
- Fixed (N1): a flagged attachment logged an error on every sync before the second attempt
  succeeded. The first attempt logs at `.debug`; the mapper logs the outcome.
- Fixed (N2, N3, N4), wording: D2 no longer says a create entry can't be lost during a sync (it
  can, together with the item, and the next sync brings both back); the "Org key missing"
  scenario starts from an item listed by an earlier sync, since an item whose org key fails at
  sync is not listed at all; spec and task 5.1 name official clients in general, and the rig used
  the `bw` CLI.
- Fixed (VoiceOver check 2026-10-30, Christian): the note sat inside the row's `Label`, which
  VoiceOver reads as one element, so it could not reach the note. The row is no `Label` now; name
  and size are one element, the note is its own.
- Open, pre-existing (not introduced here): the sync checks that the vault is unlocked and then
  writes the key cache in a separate step. A lock between the two leaves the new sources, item
  keys included, in the cleared cache until the next sync replaces them. The same gap existed for
  item keys before this change. Moved to the change request `lock-state-machine` (Christian,
  2026-10-30).

Security review (task 5.2), on the code as it is now:

- **Key selection:** the item's own key, otherwise the org key for an org item, otherwise the
  vault key, as in SDK `decrypt_cipher_key` and `key_identifier`. Sync records the source of
  every item, once, after the org pass; a create records the source of the new item. An unknown
  item throws `cipherKeyUnavailable` and a missing org key throws `organizationKeyUnavailable`;
  neither falls back to the vault key. In attachment code `currentKeys()` is reached only through
  `personalKey()`, which only flagged attachments use (download and conversion).
- **The vault-key attempt in the mapper** runs only for org items without their own key, after
  the org key failed. It decrypts only the file name; the attachment key stays wrapped until a
  download. The EncString MAC is checked before decryption, so it cannot produce wrong
  plaintext, and the key is one the user already holds.
- **Lock:** `clear()` bumps the cache generation and zeroes each item key in place (taken out of
  the dictionary first, so copy-on-write cannot leave the original). A create that finishes after
  a lock records nothing. Org and vault keys are never copied into the cache; they stay in
  `OrgKeyCache` and the crypto service, which are cleared on lock too. The one gap is the
  pre-existing sync window above.
- **Logs:** cipher and attachment IDs, org-ID prefixes and counts only; no key bytes and no file
  names.

**Archive pass (2026-10-30, `/opsx:verify`).**
- Fixed: the main spec `attachment-crypto` still said a keyless item's attachment key is wrapped
  with the vault key. A MODIFIED delta now names the effective key and rules out the vault key for
  organization items; the proposal lists the capability.
- Accepted: the second half of "Attachment on a new org item before the next sync" (the file is
  still listed and opens after the next sync) has no test of its own. After a sync the key source
  comes from the sync, which is tested for org items without their own key, so the create-time
  record no longer matters.
- Accepted: "Org key missing" is tested at the key service; that no request is sent follows from
  the upload use case asking for the key first.

## Open Questions

1. How many users have wrongly keyed org attachments? Unknown. The detection in D3 logs a count
   per sync, so the maintainer can ask users to report it.
