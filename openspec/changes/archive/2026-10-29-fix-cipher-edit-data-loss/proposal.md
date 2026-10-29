# Proposal

## Why

Saving an edited item in Prizm can destroy data that other Bitwarden clients stored on it. Users
get no warning. They find out later, when a passkey, a password history, an attachment, the
archived state or an SSH key is gone. Items that official clients gave their own encryption key
cannot even be opened in Prizm. Five defects in the read and edit path
(`CipherMapper.map`, and `VaultRepositoryImpl.update` → `CipherMapper.toRawCipher` →
`PUT /api/ciphers/{id}`) cause this.

Since `fix-favorite-and-folder-partial-updates`, starring an item and moving it to a folder use
`PUT /api/ciphers/{id}/partial`, which carries no item data and cannot drop fields. Every other edit
still takes the path above.

**1. Items with their own key are not readable.** Official clients can give an item its own
symmetric key (`key`, wrapped with the vault or org key). All fields of such an item are encrypted
with that key. `CipherMapper.map` unwraps `key`, but uses it only for attachments: name, notes,
custom fields and type content are decrypted with the vault or org key
(`Prizm/Data/Mappers/CipherMapper.swift`, `map(raw:vaultKeys:orgKeys:)`). Their MAC check fails, and
the item is dropped from the vault as a failed cipher (the drop is observed on a Vaultwarden test server,
design.md "Server behavior" E0; the MAC failure behind it is source-reviewed).

Keyed items are becoming the norm. Bitwarden SDK commit `095bfda` (2026-10-05) removed the
`cipher-key-encryption` feature flag: from SDK build 1087 on, every create, and every edit of an
item without a key, adds a per-item key. The Bitwarden iOS app already keys every item. Browser
extension 2026.10.0 still pins an older SDK build, which keys items only when the server sends the
flag. Vaultwarden 1.37.3 did not send it (its `/api/config` answer was checked, tested 2026-10-26),
and the 1.37.4 source does not list it among the flags it can send (source-reviewed, not tested).
The next client releases will key items on Vaultwarden too.

**2. Fields Prizm does not model are dropped.** `toRawCipher` builds a fresh `RawCipher` with only
the fields Prizm models. Vaultwarden and the official server replace the stored cipher data with the
request body (Vaultwarden 1.37.4 tested, design.md "Server behavior" E2; official server
source-reviewed), so every edit deletes:
- `login.fido2Credentials`: **passkeys** created by the Bitwarden browser extension or mobile apps
- `passwordHistory`, on every item type
- `archivedDate`: on Vaultwarden 1.37.3 and 1.37.4, an edit un-archives the item (tested on a
  Vaultwarden test server; later versions were not tested)
- `sshKey.keyFingerprint`: Prizm sends `nil` (the code comment calls it "server-authoritative"; no
  server derives it: Vaultwarden 1.37.4 tested, E8, the official server source-reviewed, not
  tested). Vaultwarden then returns `sshKey: null` (tested on a test server), so after
  any edit the SSH key disappears from every client.
- `login.passwordRevisionDate`, `login.autofillOnPageLoad`, `login.uris[].uriChecksum`
- any field a newer server or client adds inside `login`, `uris[]`, `card`, `identity`, `sshKey` or
  `fields[]`

A missing `uriChecksum` is not cosmetic: on keyed items, official clients hide a URI whose checksum
is missing or wrong, and their next save deletes it.

**3. Per-item keys are ignored on write.** `update()` encrypts with the vault or org key
(`encryptionKeys(for:)` in `VaultRepositoryImpl.swift`; since `fix-org-key-required-on-write` it
fails instead of falling back to the vault key when the org key is missing), and `toRawCipher`
always sends `key: nil`. Vaultwarden and the official server clear the stored `key` when the request omits it
(tested on Vaultwarden 1.37.4, design.md "Server behavior" E2; official server source-reviewed).
The fields are then readable with the vault or org key, but the attachment keys, still wrapped with the old item key, are not: the item's
attachments are lost.

**4. No stale-write protection.** `RawCipher` has no `lastKnownRevisionDate`. Without it, the server
cannot reject an update based on an outdated copy. If an item was changed on another device after
Prizm's last sync, saving in Prizm silently overwrites that change.

**5. Saves fail on Vaultwarden 1.37.4.** Vaultwarden 1.37.4 requires `encryptedFor` (the user's id)
in every cipher create and update body and answers HTTP 422 without it. Prizm does not send it, so
every item create and every item edit fails there with "Server error 422." Checked on a Vaultwarden 1.37.4 test server
on 2026-10-26: Prizm's own update body was rejected with 422 and accepted once `encryptedFor` was
added. Starring, folders, delete and collections still work. Vaultwarden 1.37.3 accepts Prizm's
bodies.

Every Prizm user who edits items is exposed to defect 4, and every user of Vaultwarden 1.37.4 to
defect 5. Users who also use official Bitwarden clients (passkeys, password history, archive, SSH
keys, per-item keys) are exposed to defects 1 to 3. The fix should land before any new feature
work.

## What Changes

- **Read with the effective key.** `CipherMapper.map` decrypts every field of an item with its own
  key when it has one, otherwise with the vault or org key.
- **Keep the last server record.** Prizm keeps the last server-confirmed `RawCipher` per item in
  memory, as ciphertext, in a shared Data-layer store. It is cleared on lock and sign-out.
- **Write over that record.** An edit sends the stored record with only the fields the user can edit
  replaced. Values Prizm does not edit (passkeys, password history, archived date, SSH fingerprint,
  unknown nested keys) are copied as ciphertext, never decrypted. Response-only keys such as `data`
  and the legacy `login.uri` are never sent back.
- **Write with the effective key.** Edited fields are encrypted with the item's own key when it has
  one, and the original wrapped `key` is sent back unchanged. A missing key, org key or stored record
  fails the save; nothing falls back to another key.
- **Field rules.** Every URI gets a freshly computed `uriChecksum` on every save and create.
  `passwordRevisionDate` is set when the password is changed, added or cleared.
- **Refuse what cannot be round-tripped.** Items in a format Prizm cannot write back losslessly
  cannot be edited, and the detail pane says why.
- **`encryptedFor`.** Every create and full update carries the user's id from the last sync.
- **Stale-write protection.** Every full update sends the stored record's `revisionDate` as
  `lastKnownRevisionDate`. Prizm refreshes that record after each of its own changes, so they do
  not cause a false conflict; when the refresh finds that another client changed the item's content,
  the next save is rejected as a conflict instead. When the server rejects an update as out of date, the edit sheet shows
  that the item was changed on another device, announces it to VoiceOver, syncs, keeps the user's
  input visible, and blocks Save until the user reloads the item.

## Capabilities

### New Capabilities
- `vault-item-edit-roundtrip`: items with their own key are readable, and updates never destroy
  server data that the user did not change, nor overwrite a newer remote change.

### Modified Capabilities
- `server-error-texts`: an out-of-date rejection shows Prizm's conflict message instead of the
  server's text.
- `cipher-partial-update`: a favorite change or move is followed by one fetch of the item, and the
  cached revision follows that record only when the item's content is unchanged.
- `detail-column-header`: Edit is also disabled for an item that cannot be edited.

## Non-Goals

- Modelling passkeys in the Domain, or showing them in the UI. That is `passkey-support`, which
  builds on this fix.
- Showing password history, or appending the old password on change. That is `password-history`.
  Until then Prizm preserves the history but does not add to it.
- Giving new items their own key, or keying existing items on edit. New items are created without
  a per-item key, as today; `per-item-key-on-create` covers that.
- SSH key handling beyond keeping the fingerprint on edit: read-only key fields, incomplete SSH
  items and SSH key creation. That is a possible follow-up change, `fix-ssh-key-roundtrip`. This
  change only stops an edit from deleting the fingerprint.
- Merging conflicting edits, or retrying automatically. On a conflict the user reloads and
  re-applies the edit.
- A manual Sync control. The sync after a conflict is the only new sync trigger.
- Offline edit queueing (existing TODO in `VaultRepositoryImpl.update`).
- The full-PUT fallback for servers whose `/partial` is broken (Bitwarden with an Entity Framework
  backend). `fix-favorite-and-folder-partial-updates` deferred it until this change makes a full
  PUT lossless; it is a follow-up.
- Lock races beyond this change's own store and save path. Those belong to `lock-state-machine`.
- Fault-tolerant per-item sync decode, blob or V2 (COSE) ciphers, and item types 6–8. See design.md,
  Known gaps.
- Changing the declared client version (`Bitwarden-Client-Version: 2024.12.0`) to engage the
  official server's passkey edit gate. That would misreport the client.
- Repairing items already damaged by the bug. The data is gone from the server.

## Impact

- **Data:**
  - `Prizm/Data/Network/Models/RawCipher.swift`: new typed fields, opaque JSON values for preserved
    data, nested unknown-key carry-over, an exclusion list for response-only keys
  - a new shared `RawCipherStore` actor, created once in `AppContainer` and used by
    `SyncRepositoryImpl` and `VaultRepositoryImpl`
  - `Prizm/Data/Mappers/CipherMapper.swift`: effective key on read and write, overlay on the stored
    record, `uriChecksum`, `passwordRevisionDate`
  - `Prizm/Data/Repositories/VaultRepositoryImpl.swift`: key selection, store hooks, revision
    refresh, conflict mapping, per-item write serialisation
  - `PrizmAPIClient`: a single-cipher `GET` (`getCipher`, with a 10 s idle timeout, so a stalled
    refresh cannot hold the per-item queue), `restoreCipher` and the collection update
    (`/collections`) returning the cipher; a 2xx answer with no usable cipher counts as none
    (`performOptional`). `encryptedFor` needs no change here: it travels in `RawCipher`, so create
    and update bodies carry it
  - `VaultKeyServiceImpl` (whose cache-miss fallback is the vault key) is not used on the write path.
- **Domain:** new `VaultError` cases (conflict and save-time failures), an edit-block reason on
  `VaultItem`, and a session token that a sync hands to `VaultRepository.populate`, so a sync that
  finishes after lock changes nothing. Foundation only.
- **Presentation:** `ItemDetailView` and `VaultBrowserView` (Edit disabled with a reason, also as
  the button's accessibility hint), `ItemEditViewModel` and `ItemEditView` (conflict state, reload
  action, VoiceOver announcement, synchronous `isSaving`), `VaultBrowserViewModel` (sync after a
  conflict; `triggerEdit` ignores a blocked item). `ItemEditView` imports AppKit for the
  announcements: SwiftUI's announcement ignores the priority macOS VoiceOver needs here (design D7
  gives the reason; §I allows AppKit where SwiftUI has no equivalent and asks for the use to be
  documented, and an OpenSpec change has no Complexity Tracking table, so this line and D7 are
  that record).
- **App:** `AppContainer` and `PrizmApp` wiring; the Edit menu item is disabled for an item with an
  edit block; the UI-test seeding seeds raw records (`AppContainer.seedUITestRecords`,
  `UITestFixtures.rawRecords`); debug-only conflict scenarios in the UI-test vault (a save rejected
  as outdated, followed by a sync that changes the item, fails once or removes it) for the UI
  journeys; a DEBUG-only `populate` overload without a session token for tests and the UI-test seam.
- **Docs:** `ACCESSIBILITY.md`: the conflict banner's announcements (criteria 3.3.1 and 4.1.3) and
  a new known gap, the disabled Edit button of an item Prizm cannot edit.
- **Create:** `vault-item-create` gets no delta; its create request now carries `encryptedFor`
  (D5), which the new requirement "Saves identify the user they were encrypted for" states for
  creates and updates.
- **Tests:** existing `update` tests and test doubles change, because an edit now needs a stored
  server record.
- **No new dependencies.** SHA-256 for `uriChecksum` comes from CryptoKit, in the Data layer.
- **Security review required** (§III: vault-touching code, key selection on the write path).
- **Verification:** tested against Vaultwarden 1.37.4 (and 1.37.3 where version-sensitive) on a
  Vaultwarden test server. The official Bitwarden server is source-reviewed, not tested.
- **References** to `passkey-support`, `password-history`, `per-item-key-on-create`,
  `fix-ssh-key-roundtrip`, `lock-state-machine`, `fix-encstring-validation`,
  `fix-attachment-file-format`, `fix-attachment-transfer-flow` and
  `macos-autofill-credential-provider` mean possible follow-up changes. None of them exists in this
  repository, and this change does not depend on any of them.
- **Possible follow-ups:** `passkey-support`, whose passkey storage and registration would rely on
  this round-trip, and `per-item-key-on-create`, which would replace this change's "new items get
  no key".

## Estimate

Ideal engineer-days, TDD included. The Vaultwarden test server is a prerequisite and is not counted.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Fixture and recorded server behavior (E0–E9) | 1–1.5 d |
| 2 | `encryptedFor`; wire model and record store | 1.75–2.5 d |
| 3 | Effective-key read and write, overlay, field rules, edit guard | 3–4 d |
| 4 | Stale-write protection (Data) and conflict UX (Presentation) | 3–4 d |
| 5 | Reviews, live verification, CHANGELOG, OpenSpec sync | 1–1.5 d |
| **Total** | | **9.75–13.5 d** |
