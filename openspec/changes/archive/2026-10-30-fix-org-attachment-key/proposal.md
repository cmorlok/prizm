# Proposal

## Why

**Criticality:** P0 (Critical)
**Findings:** S-01 (`03-sync-read.md`), A-02 (`05-attachments-totp-icons.md`)

Attachment operations get the item's key from `VaultKeyServiceImpl.cipherKey(for:)`. That service
returns the cached key if there is one, and otherwise the user's **personal vault key**
(`VaultKeyServiceImpl.swift:43-65`). Sync caches only items that have their own key
(`PrizmCryptoService.swift:302-306`, `SyncRepositoryImpl.swift:251`). So for every **organization item
without its own key**, Prizm uses the wrong key:

- **Upload:** the attachment key and file name are encrypted with the user's personal key. No
  other member of the organization can open the file. After the next sync, Prizm itself fails to
  decrypt the file name with the org key and silently drops the attachment from the list
  (`CipherMapper.swift:161-169`). The user sees the file vanish, but it still uses storage.
- **Download:** the attachment key can't be unwrapped, and opening fails with a decryption error.

This isn't limited to new items before a sync (the case `per-item-key-on-create` D4 describes).
It hits every org item without its own key: all org items Prizm creates, and all org items created
by official clients before they started giving items their own key.

## Origin of the current behaviour

**Accidental.** The key cache was added for personal items in `6f5bfff` (#31). Org support
(`923fa5b`) only refreshed the cache after the org pass (today `SyncRepositoryImpl.swift:269`).
`openspec/changes/archive/2026-04-19-org-support/design.md` §2 says "VaultKeyCache stores
per-cipher effective keys (unchanged)". The fallback comment says "Ciphers with no per-item key
(use vault-level key directly, per Bitwarden spec)" (`VaultKeyServiceImpl.swift:16`) and doesn't
consider organizations.

## What Changes

- **Resolve the effective key correctly.** Item key if the item has one; otherwise the org key for
  an org item; otherwise the vault key for a personal item. If the org key is missing, or Prizm
  doesn't know the item, fail with a typed error. Never fall back to the vault key for an org item.
- **Know every item.** Sync records the key source of every item (own key, org, personal), not
  only items with their own key. A successful create records it right away.
- **Find attachments that were saved with the wrong key.** When an org attachment's file name
  doesn't decrypt with the org key but does with the vault key, Prizm keeps the attachment, marks
  it, and can still open it with the vault key. The row says only the user can open it.
- **Repair them by conversion.** Every such file was uploaded by Prizm, so it is also in Prizm's old
  file layout. Re-wrapping the key alone wouldn't make it readable for others. The repair is the
  conversion in `fix-attachment-file-format`, which re-uploads the file under the correct key.

## Capabilities

### New Capabilities
- `attachment-key-resolution`: which key Prizm uses for an item's attachments, and how attachments
  that were wrapped with the wrong key are found and repaired.

### Modified Capabilities
- `attachment-crypto`: the requirement "Attachment key encrypted with cipher key" said a keyless
  item's attachment key is wrapped with the vault key. It now names the effective key, and never
  the vault key for an organization item. Related: `openspec/specs/org-key-crypto/spec.md`.

## Non-Goals

- Items encrypted with the personal key at **create or update** when the org key is missing
  (finding W-04): `fix-org-key-required-on-write`. The rule here is the same: no
  fallback.
- Giving new items their own key (`per-item-key-on-create`).
- Repairing the key alone with `attachments2` on `PUT /api/ciphers/{id}` (design D4, rejected).
- Admin-console attachment access (`adminRequest: true`).

## Dependencies

- **None (hard)** for the key resolution fix.
- **Repair is delivered by** `fix-attachment-file-format` (conversion). That change depends on this
  one. Release both together.
- **Branch:** stacked on `fix-attachment-transfer-flow` (`fix/026`). There is no functional
  dependency, but both edit `Attachment`, `AttachmentMapper` and the attachment row, and
  `fix-attachment-file-format` needs both; one stack keeps the three PRs free of conflicts.
- **Dependent:** `per-item-key-on-create` depends on this change. Its design D4 ("cache the key on
  create; fix the cache-miss fallback") is covered here. After this change, it only has to record
  the item key source on create instead of the org/personal source.

## Impact

- **Data:**
  - `VaultKeyCache`: stores a `CipherKeySource` per item instead of raw keys for keyed items only.
  - `VaultKeyServiceImpl`: resolves through `VaultKeyCache` and `OrgKeyCache`; new init parameter.
  - `PrizmCryptoService.decryptList` and `SyncRepositoryImpl`: record a source for every item.
  - `VaultRepositoryImpl.create`: records the source after a successful create.
  - `CipherMapper` / `AttachmentMapper`: second try with the vault key for keyless org items.
- **Domain:** `VaultError.cipherKeyUnavailable` (new; `organizationKeyUnavailable` is reused);
  `Attachment.wrappedWithPersonalKey: Bool`.
- **Presentation:** a warning on affected attachment rows, with VoiceOver text; error messages for
  the two new errors.
- **No new dependencies.**
- **Security review required** (§III: key selection for encryption).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm official key rule, reproduce the bug in a test | 0.5 d |
| 2 | Key source cache, resolution, typed errors | 1 d |
| 3 | Record sources on sync and on create | 0.5 d |
| 4 | Detect wrongly keyed attachments, open them, row warning, VoiceOver | 1–1.5 d |
| 5 | Interop check, security review, CHANGELOG | 0.5 d |
| **Total** | | **3.5–4 d** |
