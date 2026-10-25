# Proposal

## Why

**Criticality:** P0 (Critical: destroys data now)
**Findings:** W-04 (`04-write-paths.md`)

**An org item can be saved encrypted with the user's personal key.** `update()` and `create()`
pick the encryption key like this (`Prizm/Data/Repositories/VaultRepositoryImpl.swift:274-280` and
`:325-331`):

```swift
if let orgId = draft.organizationId, let orgKey = orgKeysSnapshot[orgId] {
    encryptionKeys = orgKey
} else {
    encryptionKeys = vaultKeys
}
```

If the org key is missing, Prizm falls back to the personal vault key but still sends
`organizationId`. The server stores an org item that no other member can decrypt. Prizm's own next
sync fails to decrypt it too (MAC failure) and hides it. The item is lost for everyone until the
user who saved it re-saves it from a client that has the org key.

**The org key is missing during every sync.** `SyncRepositoryImpl` clears the whole `OrgKeyCache`
before it unwraps the new keys (`Prizm/Data/Repositories/SyncRepositoryImpl.swift:150`). A save that
reads the cache in that window takes the fallback. If the org key unwrap fails, or the sync is
cancelled or fails after the clear, the cache stays empty and *every* org save takes it until the
next successful sync. The probability per save is low, but the result is silent and permanent.

### Origin of the current behaviour

**Accidental.** The danger was known: commit `923fa5b` says "caller must pass org key from
OrgKeyCache; without this org saves encrypt with personal vault key". The fix passed the org key
when present but kept the fallback for when it is absent. The clear at the start of sync is
commented "Fresh slate for this sync" and does not consider concurrent saves.

## What Changes

- **No fallback.** If an item has an `organizationId` and its org key is not available, create
  and update throw `VaultError.organizationKeyUnavailable` before anything is encrypted or sent.
  The user sees "This item's organization can't be accessed right now. Sync and try again." and the
  sheet stays open with their input.
- **No empty window during sync.** Sync builds the new org-key map on the side and swaps it into
  `OrgKeyCache` in one actor call. A save sees either the old keys or the new ones, never none. If
  sync fails before the swap, the old keys stay.
- **An org that left the sync loses its key.** After a successful swap, orgs no longer in the sync
  response have no key, so saves to them fail closed.

## Capabilities

### New Capabilities
- `org-key-write-guard`: org items are only ever encrypted with their org key; the org key stays
  available while a sync runs.

### Modified Capabilities
_None._ `openspec/specs/org-key-crypto/spec.md` covers unwrapping, not key selection on write.

## Non-Goals

- Attachment key fallback. `VaultKeyServiceImpl.cipherKey(for:)` falls back to the vault key on a
  cache miss; that is audit finding 05 A-02 / 03 S-01 and is fixed in `per-item-key-on-create` (D4)
  and `fix-org-attachment-key`.
- Per-item key selection (effective key) on update. That is `fix-cipher-edit-data-loss` D1.
- Org key rotation. Neither server rotates org keys in normal use; Prizm picks up a new key at the
  next sync.
- Repairing items already saved with the wrong key. Prizm cannot find them (they fail to decrypt
  with the org key, and nothing marks them). The CHANGELOG explains how to recover from an
  official client.

## Dependencies

**Overlap with `fix-cipher-edit-data-loss`.** Its GSD requirement KEY-03 says: "Save fails with an
error, never falls back to another key, when the org key or the stored server record is missing."
The OpenSpec artifacts of that change do not state this yet: its design D1 says only "falling back
to the org or vault key when the cipher has none", which is ambiguous for a missing org key.

- This change owns the rule for **both** create and update, and the sync race.
- KEY-03's "org key missing" part is the same rule. Whichever change lands first implements the
  guard in `update()`; the other keeps a regression test only. KEY-03's "stored server record
  missing" part stays in `fix-cipher-edit-data-loss`.
- When this change is archived, `fix-cipher-edit-data-loss` D1 should be read as "org items use the
  org key or fail".
- `per-item-key-on-create` D2 states the same rule for wrapping the new item key ("If the org key
  is missing, the save fails"). It should depend on this change (soft).

Hard dependencies: none. Soft: `fix-cipher-edit-data-loss`, `per-item-key-on-create` (consistency).

## Impact

- **Data:**
  - `OrgKeyCache`: new `replaceAll(with:)` that swaps the map and zeroes the replaced keys.
  - `SyncRepositoryImpl`: unwrap into a local dictionary, then swap; no `clear()` at sync start.
  - `VaultRepositoryImpl.create` / `update`: one shared `encryptionKeys(for:)` helper that throws.
- **Domain:** `VaultError.organizationKeyUnavailable` with a user-facing message.
- **Presentation:** `ItemEditViewModel` shows the error inline and announces it (§VIII).
- **No new dependencies.**
- **Security review: yes** (key selection on the write path, key lifetime in the cache; §III).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Guard in create and update, error type and message | 0.5 d |
| 2 | Atomic key swap in sync; race test | 0.5–0.75 d |
| 3 | Edit-sheet error, VoiceOver | 0.25 d |
| 4 | Security review, CHANGELOG | 0.25–0.5 d |
| **Total** | | **1.5–2 d** |
