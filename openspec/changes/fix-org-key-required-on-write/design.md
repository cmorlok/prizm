# Design

## Context

**Official (SDK).** The key for a cipher comes from its owner: `Cipher::key_identifier` returns
`SymmetricKeySlotId::Organization(id)` when `organization_id` is set and `User` otherwise
(`sdk-internal/crates/bitwarden-vault/src/cipher/cipher.rs:1431-1438`; the same for `CipherView`,
`:1686-1693`). Looking up a key that is not in the store fails with `CryptoError::MissingKeyId`
(`sdk-internal/crates/bitwarden-crypto/src/store/context.rs:626-641`). There is no path that
substitutes the user key for an org key. The web client also refuses to encrypt collection data
without the org key ("No key for this collection's organization.",
`clients/libs/admin-console/src/common/collections/services/default-collection-admin.service.ts:163-178`).

**Servers.** Neither server can check which key encrypted a field. Both store an org item
encrypted with the wrong key as is. (Vaultwarden 1.37.4 checks `encryptedByKeyId` only for personal
`POST /ciphers`, `vaultwarden/src/api/core/ciphers.rs:394-399`.)

**Prizm today.**
- Fallback in `update()` and `create()`: `VaultRepositoryImpl.swift:274-280`, `:325-331`.
- `encryptCollectionName` already throws when the org key is missing (`VaultRepositoryImpl.swift:568-572`).
  So collections already fail closed; only items don't.
- `SyncRepositoryImpl.swift:148-160`: `await orgKeyCache.clear()`, then one `store` per org. A
  failed unwrap is logged at `.fault` and skipped.
- `OrgKeyCache` (`Prizm/Data/Crypto/OrgKeyCache.swift`) is an actor with `store`, `snapshot` and
  `clear`. `clear()` zeroes the key bytes before removing them. It is also cleared on lock and
  sign-out (`Prizm/App/PrizmApp.swift:485`).
- Writes take a snapshot once at the start (`VaultRepositoryImpl.swift:274`, `:325`), so a save
  that starts before a swap keeps using the old, still valid key.

## Goals / Non-Goals

**Goals**
- An org item is encrypted with its org key or not saved at all.
- A sync never makes org keys temporarily unavailable.
- The user gets a clear, recoverable error.

**Non-Goals:** see proposal.md.

## Decisions

### D1. One key-selection helper that throws

```swift
/// Security goal: an org item must only ever be encrypted with its organization key. Encrypting
/// it with the user's key makes it unreadable for every other member and for this user's next
/// sync. Mirrors the SDK's key_identifier (cipher.rs:1431), which has no fallback.
private func encryptionKeys(for draft: DraftVaultItem, vaultKeys: CryptoKeys,
                            orgKeys: [String: CryptoKeys]) throws -> CryptoKeys
```

- `organizationId == nil` → vault key.
- `organizationId` set and key present → org key.
- `organizationId` set and key absent → `throw VaultError.organizationKeyUnavailable`.

`create()` and `update()` call it before `toRawCipher`, so no request is built. The
`fix-cipher-edit-data-loss` effective-key logic (own item key first) wraps around this helper; it
does not replace it.

**Rejected alternative:** wait for a running sync to finish, then retry. It hides the cause and
still fails when the org key unwrap itself failed.

### D2. Swap the key map atomically

`OrgKeyCache.replaceAll(with newKeys: [String: CryptoKeys])`:
1. keeps the old map in a local,
2. assigns the new map,
3. zeroes the old entries' bytes (same code as `clear()`, extracted into one private function).

`SyncRepositoryImpl` unwraps all org keys into a local `[String: CryptoKeys]` and calls
`replaceAll` once, where `clear()` was called before. If the sync throws before that point, the
cache is untouched. Orgs whose unwrap failed are absent from the new map (D1 then makes their saves
fail, which is right: Prizm cannot decrypt them either).

Zeroing follows the existing documented limitation: snapshots held by in-flight saves keep their own
copy until they end (`OrgKeyCache.swift:57-59`, SECURITY.md).

**Rejected alternative:** keep `clear()` and make writes `await` the sync. It couples the vault
repository to sync state, and a failed sync still leaves an empty cache.

### D3. Error message

`VaultError.organizationKeyUnavailable` → "This item's organization can't be accessed right now.
Sync and try again." The edit and create sheets show it inline, keep the user's input, and announce
it to VoiceOver. The log entry is `.error` with the org id prefix (8 chars), like the existing
sync logs. No key material is logged.

## Risks / Trade-offs

- **[Low] More visible errors.** A user whose org key unwrap fails now gets an error on save instead
  of a silent wrong save. That is the intent.
- **[Low] Old keys live slightly longer.** During a sync the old map stays until the swap, instead
  of being zeroed at the start. The keys are the same keys in almost every case; the window is one
  sync.

## Open Questions

1. A failed org key unwrap is only logged at `.fault` (`SyncRepositoryImpl.swift:158`). Its items
   and collections are skipped, so the UI cannot reach a save for that org, and D1 blocks it anyway.
   Should the sync status also tell the user that an organization could not be unlocked? Left to the
   sync-status work.
