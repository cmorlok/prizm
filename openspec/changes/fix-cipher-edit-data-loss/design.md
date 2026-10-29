# Design

## Context

**Today's read path.** `CipherMapper.map(raw:vaultKeys:orgKeys:)` picks the active key (the org key
for an org item, otherwise the vault key) and decrypts name, notes, custom fields and type content
with it. Only after that does it unwrap the item's own `key`, and it uses the result for attachments
only. `SyncRepositoryImpl` puts that unwrapped key into `VaultKeyCache`, which `VaultKeyServiceImpl`
serves to the attachment code. An item whose fields are encrypted with its own key fails the MAC
check and is dropped as a failed cipher (`PrizmCryptoService.decryptList`, `failedCount`).

**Today's edit path.**
1. `ItemEditViewModel` builds a `DraftVaultItem` from the decrypted `VaultItem`. On save it
   normalises the draft (`normalisedForSave`, `card-field-normalisation`): card brand and expiry
   are rewritten in the official format, and blank website rows are dropped.
2. `VaultRepositoryImpl.update(_:)` sends a change of only folder or favorite through
   `PUT /api/ciphers/{id}/partial` (`org-items-in-personal-folders`; the `/partial` call itself comes
   from `fix-favorite-and-folder-partial-updates`) and stops there.
   For every other change it picks the keys with `encryptionKeys(for:)`: the org key for an org
   item, failing with `VaultError.organizationKeyUnavailable` when it is missing
   (`fix-org-key-required-on-write`), otherwise the vault key.
3. `CipherMapper.toRawCipher(draft, encryptedWith:)` builds a fresh `RawCipher` with `key: nil`,
   `attachments: nil`, and only the fields Prizm models.
4. `PUT /api/ciphers/{id}`; for an org item then `PUT /api/ciphers/{id}/collections`, and the
   cached `collectionIds` are patched from the draft.
5. The response is mapped back and the in-memory item list is patched.

The body has no `encryptedFor`, so Vaultwarden 1.37.4 rejects step 4 (and every create) with HTTP
422 (tested on a Vaultwarden 1.37.4 test server, 2026-10-26; see D5).

Vaultwarden and the official server replace the stored cipher data with the request body
(Vaultwarden 1.37.4 tested, "Server behavior" E2; official server source-reviewed, not tested).
Anything `RawCipher` never decoded is absent from the body in step 4, so it is deleted on the
server.

**Fields the server stores that Prizm drops today.** Sources: Bitwarden SDK
`bitwarden_vault::cipher`, Vaultwarden 1.37.4 `src/db/models/cipher.rs`.

| Field | Where | Encrypted? | Rule in this change |
|---|---|---|---|
| `key` | cipher | EncString (item key wrapped with vault or org key) | sent back byte for byte (D2) |
| `fido2Credentials[]` | `login` | every sub-field an EncString except `creationDate` | copied as ciphertext |
| `passwordRevisionDate` | `login` | no (date string) | SDK rules (D3) |
| `autofillOnPageLoad` | `login` | no (bool) | copied |
| `uriChecksum` | `login.uris[]` | EncString of base64(SHA-256(uri)) | recomputed (D3) |
| `passwordHistory[]` | cipher, every type | `password` EncString, `lastUsedDate` string | copied as ciphertext |
| `archivedDate` | cipher | no (date string) | copied |
| `keyFingerprint` | `sshKey` | EncString | copied as ciphertext |
| unknown keys | `login`, `uris[]`, `card`, `identity`, `sshKey`, `fields[]` | as received | copied |

**Request-only fields this change adds:** `encryptedFor` (D5) and `lastKnownRevisionDate` (D6).

**Never sent back.** These come in responses but must not be in a request:
- `data`: the official server stores a non-blank `data` verbatim and ignores the typed fields, so
  the edit would be lost (source-reviewed, not tested). Vaultwarden 1.37.4 sends no `data` (its sync
  fixture has none, tested), so a Vaultwarden test cannot catch this.
- legacy `login.uri`: the official server appends it to `uris`, duplicating a URI
  (source-reviewed, not tested).
- `attachments` (Prizm sends none), `edit`, `permissions`, `object`, `organizationUseTotp`,
  `partialData`, a nested `response` if present, and any other response-only key the captured
  fixtures reveal.

## Goals / Non-Goals

**Goals**
- Items with their own key are readable.
- A `PUT` never removes or corrupts server data that the user did not change in this edit.
- A `PUT` never overwrites a newer change made elsewhere.
- No plaintext handling of fields Prizm does not display: preserved values stay encrypted.
- Prizm's own operations do not cause a false conflict, and never hide a real one.

**Non-Goals:** see proposal.md.

## Decisions

### D0. Read every field with the effective key

`CipherMapper` gets one shared function, `effectiveKeys(for: raw, activeKeys:)`, used by `map` and by
the write path (D2). It unwraps `raw.key` with the active key (org key for an org item, vault key
otherwise) when present, and returns the active key when not. The unwrapped key is built with
`CryptoKeys(data:)`, which checks that it is exactly 64 bytes, so a key of another length fails
instead of being cut to size. `map` resolves it first and decrypts every field and the attachments
with it.

- If the unwrap fails, or a field fails to decrypt with the effective key, the item is dropped and
  counted, as every decrypt failure is today. There is no retry with the vault or org key: a
  fallback would make mixed-key items visible and editable (rbw#364 is that bug).
- An item key that is not an EncString of type 2 is refused before it is decrypted, and the item is
  dropped and counted like any unwrap failure. Type 0 has no MAC, so nothing would authenticate the
  key that every field is then read with; type 1 and other types are not supported by
  `EncString` at all. The same rule applies on write (D2 step 7).
- Dropping the whole item when one field fails is Prizm's choice, not parity. The SDK's default
  decrypt keeps the item and shows that field blank, and the TS clients list failed items in a
  dialog; the SDK drops the item only in its flag-gated strict mode and when the key unwrap fails
  (source-reviewed). "No fallback to the vault or org key" matches every official client.
- D0 ships whatever experiment E0 shows (does a keyed item load in Prizm today?). The SDK decrypts
  every field with the item key, so real keyed items need it. The E0 result is recorded in
  "Server behavior" below.
- D0 is its own commit. On its own it would let keyed items be edited through the old write path
  (`key: nil`, vault key), so the same commit blocks editing of keyed items through the edit guard
  (D4). The D2 commit lifts that block.
- Between the D0 commit and the D2 commit come the lasting edit-guard reasons (D4) and the
  `uriChecksum` rule (D3). So when the D2 commit makes keyed items editable, every save already
  writes a correct checksum for each website, and no item with its own key is ever saved with a
  missing or stale one, which official clients would hide and later delete (E9).

### D1. Keep the last server record per item

A Data-only actor, `RawCipherStore`, holds the last server-confirmed `RawCipher` per item id, as
received: ciphertext and plain metadata, no keys, no plaintext.

- **One instance**, created in `AppContainer` and injected into `SyncRepositoryImpl` and
  `VaultRepositoryImpl`. Neither has a default instance, so a test cannot silently use a second one.
- **Filled by** sync (`replaceAll`, just before `populate`, including items that fail to decrypt)
  and by the server's answer to create, update, restore and the collection update; after Prizm's
  other own changes the record is fetched again (D6, task 4.4).
- **Refreshed after every one of Prizm's own changes** (D6, task 4.4).
- **Removed** on permanent delete.
- **Cleared** in `VaultRepositoryImpl.clearVault()`, the hook lock and sign-out share, together with
  the item list. `invalidate()` bumps a generation token and is the first statement of `clearVault()`;
  `clear()` then empties the store (and bumps the token a second time, which is harmless).
  The token is opaque (D6 hands it to `populate`). It is read at the start of `sync()`, `update()`,
  `create()` and the permanent-delete methods, before any network await, and passed to every
  write. A `replaceAll` from an older generation is refused: the sync stops before the account id
  is stored and before `populate`. An `upsert` or `remove` from an older generation is dropped
  without changing the save's result (what the save does with its own cache after lock is
  task 4.5). So a sync or save still running at lock cannot refill the store. A sync discarded
  this way does not block the next session: a sync only answers `syncInProgress` to a caller of
  the same generation, so the sync after unlock runs and fills the vault. The token does not
  depend on a possible `lock-state-machine` follow-up, which would have to keep calling
  `clearVault()` on lock and sign-out.
- **Never logged.** The store, `RawCipher`, the nested wire types and `JSONValue` print no values.
  A sync that brings top-level keys Prizm neither models, preserves nor knows as response-only
  logs their names once, at `.info`: at most 20 names of at most 64 characters, letters, digits
  and `_` only, never values.

**Wire model (hybrid preservation).**
- Typed fields: `uriChecksum`, `passwordRevisionDate`, `keyFingerprint` (already typed),
  `encryptedFor`, and the encode-only `lastKnownRevisionDate`, which is never read from a response.
  Dates stay `String`, exactly as the server sent them.
- `archivedDate` is held as received (`JSONValue`), not as a typed field, so a value of an unexpected type is written
  back unchanged instead of being dropped.
- Preserved values (`fido2Credentials`, `passwordHistory`) are an opaque `JSONValue`: never decoded
  into typed structs, so an odd shape cannot fail sync and no plaintext is created. `JSONValue` keeps
  integers and doubles apart and keeps `null` distinct from absent. `passwordHistory` keeps a
  `null` and an absent key apart as well. Integers and doubles stay apart, but `1.0`, `1e2` and
  `-0` are written back as integers, and a number above the 64-bit integer range as a double.
  The preserved values are EncStrings and date strings, so this does not occur in them. Preserved
  JSON nested deeper than 64 levels fails the decode of its record instead of crashing the app (a
  deeper value can exhaust a pool thread's stack); real records nest three or four levels. Such a
  record is one more case of the known gap that one undecodable cipher aborts the whole sync.
- The new typed fields decode leniently. A wrong-typed value at a nested level stays in the
  extras and is written back; a wrong-typed value at the top level is dropped. Neither aborts the
  sync.
- Unknown keys are carried only at the nested levels Prizm rebuilds (`login`, `uris[]`, `card`,
  `identity`, `sshKey`, `fields[]`). `secureNote` has no extras; the nested snapshot lists its
  keys, so a new one forces a decision. The never-sent keys listed above are dropped when
  decoding, so they never enter the store and the encoder writes everything it holds.
- `attachments` is never encoded: the request shape differs from the response (the official
  server answers 400). A `response` member at the rebuilt levels is dropped. Inside
  `fido2Credentials` entries it is kept as received (Vaultwarden 1.37.4 sends `null`), and an edit
  sends it back as received (D2).
- No top-level catch-all. The top level is a typed allowlist; `data`, `attachments` and `edit` are
  never echoed.
- A canary test fails when a captured server payload has a top-level key that is neither modelled,
  preserved nor known to be response-only. A snapshot test lists the unknown keys found at each
  nested level, so a new one forces a decision.

**Rejected alternatives**
- *Decrypt preserved values into Domain types now.* That is `passkey-support` and
  `password-history`. It would grow a bug fix into a feature and create plaintext.
- *Store the raw JSON and merge it blindly.* Responses carry keys a request must not contain (see
  "Never sent back"), and it would bypass the typed models.
- *A per-field side table in `VaultRepositoryImpl`* (this design's first version). Sync could not
  fill it without a Domain dependency, and every new field needed a new column.

### D2. Write with the effective key over the stored record

`update()` works in this order, after the folder and favorite `/partial` branch
(`org-items-in-personal-folders`), which carries no item data and needs none of it; blocked items
use that branch too (D4). Every check fails before anything is encrypted or sent. Two checks that the steps below do not list,
the revision refusal and the local pre-check, sit between step 4 and step 5 (D6, "Local pre-check").
1. The cached item's edit block (D4): a blocked item fails with `VaultError.itemNotEditable`.
2. Take the stored record for the item id. If there is none, the save fails
   (`VaultError.itemRecordUnavailable`).
3. The stored record's own edit block is checked as well (`itemNotEditable`), so the save does not
   depend on the cached item alone.
4. If the draft's organization differs from the stored record's, the save fails
   (`itemRecordUnavailable`, ids logged). A draft cannot move an item between organizations, and
   key choice always follows the stored record.
5. The active key: `encryptionKeys(organizationId:)` takes the stored record's organization and
   returns that organization's key, or the vault key for a personal item. A missing org key fails
   (`organizationKeyUnavailable`, `fix-org-key-required-on-write`).
6. The account id for `encryptedFor` (D5); a missing one fails (`profileIdUnavailable`).
7. The effective key: `CipherMapper.effectiveKeys` over the stored record's `key`. Only an
   EncString type 2 is accepted as an item key (a type-0 key has no MAC); an unwrap failure or any
   other type fails the save (`itemKeyUnavailable`).
8. **Key check:** `CipherMapper.verifyKey` decrypts the stored record's `name` with the effective
   key. The name must be an EncString type 2, so its MAC is verified first; a type-0 name has no
   MAC, proves nothing about the key and fails closed (a save of such an item is already refused at
   step 3, as `legacyEncryption`, D4). A MAC or decrypt failure fails the save
   (`itemKeyUnavailable`). The decrypted name is zeroed and never kept. The check matters most for
   items without their own key, where no MAC-checked unwrap happens. It is stricter than the
   official clients: the SDK's default edit decrypts leniently and has no such probe, and only its
   flag-gated strict mode checks like this (source-reviewed). This is Prizm's choice, not parity.
   Preserved values are intentionally not decrypted to validate them.
9. **Overlay:** `toRawCipher(_:overlaying:effectiveKeys:encryptedFor:)` builds the request over the
   stored record:
   - The draft owns, and every save re-encrypts with a fresh IV under the effective key: name,
     notes, custom field values, login username, password, TOTP, websites and their match type,
     and every card, identity and SSH key text field. Folder, favorite, reprompt, organization and
     collections are plain values from the draft.
   - The stored record supplies, as received and never decrypted: `key` (byte for byte),
     `passwordHistory`, `archivedDate`, `sshKey.keyFingerprint` and the unknown keys of the login,
     of each website, card, identity and SSH key, and of each custom field. The passkeys
     (`fido2Credentials`) and `autofillOnPageLoad` travel among the login's unknown keys.
   - Never copied from the stored record: `folderId`, `favorite`, `organizationId` and
     `collectionIds`. The edit sheet holds the user's choice for them, and a stored value would
     undo it.
   - A website takes the unknown keys of the stored website with the same text (first unused
     match), because the edit sheet adds, removes and reorders websites. The stored text is read
     under the item key only for this comparison and is not kept. A custom field takes the unknown
     keys of the stored field with the same name and the same type (first unused match in stored
     order, each stored field used once, so fields with equal names pair up in order). The sheet
     cannot add, remove or reorder fields, but the stored record can change under an open sheet,
     and pairing by position would then give one field the unknown keys of another. A field
     without a match takes none, and only the number of dropped stored fields is logged, never a
     name or value. Stored names are read under the item key for the comparison only, like the
     websites; a stored name that does not decrypt fails the save.
   - `login.passwordRevisionDate` follows D3.

Invariants: `request.key` is byte-identical to the stored `key` (or both absent). Prizm never adds
a key to an item without one. The passkeys are sent back JSON-equal to the stored record: the same
entries in the same order, the same members including `"response": null`, and every encrypted
string and date identical. Only the order of members inside one object may differ from the
server's; a JSON object is unordered (RFC 8259 §4). This is the meaning of "byte-identical
passkeys" in this change (decided).

`VaultKeyService.cipherKey(for:)` is not used on the write path: on a cache miss it returns the
vault key, also for org items.

Save-time failures use typed `VaultError` cases and the edit sheet's existing error area. The sheet
stays open with the user's input and nothing is sent. Two cases are new:
- `VaultError.itemRecordUnavailable` (no stored record, or the organization differs): "Prizm
  couldn't load this item's latest saved version. Lock and unlock the vault, then try again."
- `VaultError.itemKeyUnavailable` (the item key does not unwrap, the key check fails, or a stored
  website, custom field name or password that the save compares with the draft does not decrypt): "Prizm couldn't
  load the encryption key for this item. Lock and unlock the vault, then try again."

Like the existing org-key message they tell the user to lock and unlock the vault, because Prizm
has no manual sync.

**Live result.** Prizm with the key work saved edits of
items with and without their own key, personal and org, on Vaultwarden 1.37.4 (tested 2026-10-27,
`sha256:efb3cde9…`, extension 2026.10.0 in Chrome): the keyed passkey login (username), the keyed
org login (notes; then dragged to a folder, renamed and saved again), the keyed archived item
(notes), the keyed SSH item (name) and the keyless control (password). Every save was answered 200.
The captured request bodies show each body with the stored `key` unchanged (none for the control),
`encryptedFor` equal to the account's id, a `uriChecksum` on every website and no `data`,
`partialData` or `encryptedByKeyId`. The passkey login's `fido2Credentials` and `passwordHistory`
are JSON-equal to the fixture and its `passwordRevisionDate` is unchanged; the archived item's
`archivedDate` and the SSH item's `keyFingerprint` equal the fixture's. After a lock and unlock in
Prizm and a sync in the extension, every edited item decrypted in both. The extension showed the
passkey, both websites and the password-history entry, the archived item still archived, the SSH
key with its fingerprint, the org login in its collection with the new notes, and the control's new
password. The passkey login's attachment kept its record and file and downloaded in the extension.
In Prizm the attachment key unwrapped under the item key, but the file did not open; that is a
separate, older bug (Known gaps).

**Deviation from the official clients, and why it is safe.** The SDK gives every item its own key
and re-wraps `key` with a fresh EncString on every save. Prizm sends `key` back byte for byte and
never keys an item on edit. The existing key is valid, and re-wrapping it buys nothing. Keying new
items is `per-item-key-on-create`, which supersedes the "`create()` gets no key" rule here.

**Every edited field is re-encrypted**, as the SDK does. Re-encrypting only the fields that
changed (minimal diff) is not built. It stays a hardening option the security review can ask for.

**Rejected alternative:** re-wrap or rotate the item key on every edit. New key management for no
gain.

### D3. Field rules

- **`uriChecksum`: recomputed for every URI on every save and create.** Value:
  `EncString(base64(SHA-256(UTF-8 bytes of the URI)))` under the effective key (CryptoKit, Data
  layer), as the SDK does (`login.rs`). This replaces the first version's "keep the original
  checksum for unchanged URIs". On keyed items official clients hide a URI whose checksum is missing
  or wrong, and their next save deletes it, so every save must write a correct one. It also repairs
  items Prizm saved before. Known-answer vectors:
  - `https://example.com` → `EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk=`
  - `https://test.com` → `OWk2vQvwYD1nhLZdA+ltrpBWbDa2JmHyjUEWxRZSS8w=`
  - `""` → `47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=`

  Two more known answers come from checksums the browser extension wrote into the golden fixture:
  - `https://webauthn.io/` → `25FYYY4LSw8CKWbYR76+mFyEkF8HuR+PMbzkET+z8+Q=`
  - `https://example.com/login` → `pGF1jY9OB4Lfpv5mts3QAjxtaJTVa0hmNkeVwhG3gPA=`

  Checksums are written on create as well, under the key the fields use (the org key for an org
  item).
- **URIs without a value are never sent.** Prizm's read path already skips a URI entry without a
  `uri`, and the edit sheet drops blank website rows (`normalisedForSave`), so they leave the item on
  the next save. The mapper drops an empty website too, as a backstop. Official clients drop the
  same entries on keyed items.
- **`passwordRevisionDate`** follows the SDK's `detect_password_change`: set to now when the
  password is changed, added or cleared, kept otherwise. The comparison is between the draft and
  the stored password decrypted with the effective key, inside the mapper; the decrypted value is
  not kept. A create sends no date. Prizm writes ISO-8601 UTC with milliseconds and `Z`
  (`2026-10-27T12:34:56.789Z`); the SDK writes RFC 3339 with `+00:00`. Vaultwarden 1.37.4 accepts
  Prizm's form (tested 2026-10-27, `sha256:efb3cde9…`, the control's password change in the live
  result of D2); the official server is source-reviewed, not tested.
- **Preserved unchanged:** `fido2Credentials`, `passwordHistory` (every type), `archivedDate`,
  `autofillOnPageLoad`, `keyFingerprint`, nested unknown keys.
- **`keyFingerprint`** is copied from the stored record, so an edit no longer hides an SSH key on
  Vaultwarden or loses its fingerprint. Editing the key text still leaves the old fingerprint in
  place; read-only key fields, incomplete SSH items and SSH creation are for a possible follow-up
  change, `fix-ssh-key-roundtrip`.
- **`passwordHistory` is not appended to.** Official clients put the old password first and keep the
  last five, and also record changed or removed hidden custom fields. That is a possible follow-up
  change, `password-history`; a TODO at the point of use (`passwordHistory` in `CipherMapper`) marks
  the gap.

### D4. Refuse to edit what cannot be round-tripped

Items whose stored record Prizm cannot write back without loss get an edit-block reason on
`VaultItem` (`EditBlockReason`), set by the Data layer (`CipherMapper.editBlock(for:)`).
Presentation never looks at raw shapes.

- **Reasons and what sets them.** `data` and `partialData` are dropped at decode (D1), so
  `RawCipher` records two flags while decoding and keeps neither value:
  - `unsupportedFormat`: `data` (a string holding a JSON object, or an object) has a top-level
    `format_version`; only its presence counts, never its value. "This item uses a format Prizm
    can't edit yet. Edit it in the Bitwarden web vault or browser extension."
  - `partiallyAvailable`: `partialData` is present and not `null`. "Prizm received only part of this
    item, so it can't be edited here. Edit it in the Bitwarden web vault or browser extension."
  - `unmappable`: a login, card, identity or SSH key item (type 1, 3, 4 or 5) whose `login`, `card`,
    `identity` or `sshKey` object is absent or `null`. A secure note without its object stays
    editable, because Prizm writes `{ "type": 0 }` for it, the only generic type. "Some of this item's details are
    missing, so Prizm can't edit it without losing data. Edit it in the Bitwarden web vault or
    browser extension." So an SSH item that an earlier Prizm save left with `sshKey: null` (E8) is
    read-only in Prizm. This definition of an item whose details are missing is decided.
  - `legacyEncryption`: the stored `name` is an EncString of type 0 (AES-CBC without a MAC, written
    by early Bitwarden clients), read from the type prefix alone. Prizm reads such an item but cannot
    save it: the key check (D2 step 8) has nothing to verify, so every save would fail with the text
    for a lost key, which asks the user to lock and unlock. Blocking up front gives the real reason.
    "Prizm can't edit this item because it uses an older encryption format. Edit it in the Bitwarden
    web vault or browser extension."
  - The checks run in this order, so an item gets the first reason that applies. Technical detail
    goes to the log only (item id and reason name).
- `data` alone and `partialData: null` do not block: the official server sends both on every cipher
  (source-reviewed). `data` is dropped at decode and never sent back.
- **Where Edit is refused.** The toolbar Edit button is disabled and carries the message as its
  accessibility hint, the Item menu's Edit and ⌘E are disabled, the edit sheet does not open, and the
  detail pane shows the message as a note. The repository refuses a full save of a blocked item
  as well (`VaultError.itemNotEditable`, the same message), and re-checks the stored record (D2),
  so the UI is not the only guard.
- **What still works.** A blocked item can still be starred and moved to a folder: those changes go
  through `/partial`, which carries no item data. Local updates of a blocked item (star, move,
  delete, restore, attachments, collections) keep its reason, because they copy the item instead
  of rebuilding it.
- "Has its own key" was a temporary reason, set by the D0 commit and removed by the D2 commit.

### D5. Send `encryptedFor`

Every cipher create body (`POST /api/ciphers`; for an org item inside the `cipher` object of
`POST /api/ciphers/create`) and every full update body (`PUT /api/ciphers/{id}`) carries
`encryptedFor` with the user's id. `/partial` and `/collections` requests carry no item data and do
not get it.

The id is `profile.id` from the last sync, held in a small Data-layer actor, `ProfileIdCache` (not in
`RawCipherStore`, so this commit can be cherry-picked on its own), captured on every sync and cleared
in `clearVault()`; the sync writes it only while its store token is current. If it is missing, the
save fails with `VaultError.profileIdUnavailable` ("Prizm couldn't confirm which account this item
belongs to. Lock and unlock Prizm, then try again.") and no request is sent. The check runs after the folder and favorite `/partial` branch (which needs no
id) and after the org-key check, and before anything is encrypted.
`Account.userId` from the Keychain is not used, so a save can never carry the id of an account other
than the one whose vault was synced.

An org create needed no API-client change: the request wraps the cipher, so the field sits inside
the `cipher` object the mapper already builds.

- **Vaultwarden 1.37.4** requires the field in every cipher body (HTTP 422 without it; tested on a
  Vaultwarden 1.37.4 test server, 2026-10-26). On create it compares the value: a random id gets 422 "Invalid user cipher"
  (Vaultwarden 1.37.4 tested, "Server behavior" E1b). That an update does not compare it is
  source-reviewed, not tested. Prizm with the `encryptedFor` change
  created a personal item and an org item and updated an item on it without a 422 (tested 2026-10-27, `sha256:efb3cde9…`). The personal create and the
  update bodies are in the captured request bodies, both answered 200, with `encryptedFor` equal to
  the account's id and without `encryptedByKeyId`. The org create was observed in Prizm and in the
  web vault; its body was not captured.
- **Vaultwarden 1.37.3** accepts Prizm's bodies and ignores the field.
- **Official server** (source-reviewed, not tested): the field is optional and deprecated in favour
  of `encryptedByKeyId`; when present and not the current user, it answers 400 "Cipher was not
  encrypted for the current user. Please try again."
- **`encryptedByKeyId` is never sent.** Prizm has no key ids. Vaultwarden and the official server treat
  the field as optional (source-reviewed); Vaultwarden checks it only on `POST /api/ciphers`, and only when the user has a key id.

### D6. Stale-write protection

**Wire.** Every full update sends `lastKnownRevisionDate` = the stored record's `revisionDate`
string, exactly as the server sent it. `CipherMapper.buildRawCipher` sets it once, from the stored
record the overlay starts from (D2). A create has no stored record and never sends it; `/partial`
and `/collections` carry no item data and do not get it. Never formatted from a `Date`; never the
epoch fallback (Vaultwarden rejects it with 400, a false conflict on every save) and never a string
Prizm cannot read (Vaultwarden skips its check on a date it cannot parse). A stored revision that is
missing, empty, not a date or the epoch fails the save with `VaultError.itemRevisionUnavailable`
("Prizm couldn't confirm which version of this item you are editing. Lock and unlock the vault,
then try again.") and nothing is sent: a request without a usable revision would switch the
protection off without anyone noticing. Like the other save-time failures it starts no sync.

**Local pre-check.** One shared parser, `CipherMapper.parseRevisionDate`, reads every revision: a
fraction of three to seven digits (Vaultwarden writes six, the official server seven) or none, and
`Z` or an offset. It has no epoch fallback; it returns nil for what it cannot read. `map` reads the
item's `revisionDate` and `creationDate` through it, so the item's date and the check cannot
disagree (before, a revision without a fraction became the epoch on the item). `update()` compares
the draft's revision with the stored record's (`CipherMapper.sameRevision`): they are the same when
both round to the same whole millisecond. Any other difference, older or newer, throws
`VaultError.conflict` without a network call. Millisecond resolution is enough because the check
only has to tell two saves of the server copy apart; it is not the servers' tolerance (below).
Order of the checks in `update()`: the edit blocks and the stored record (D2 steps 1–3), the
organization match (step 4), the revision refusal above, the pre-check, then the key work (steps
5–9). The item's date stays the epoch when its revision cannot be read, but such a save never gets
past the refusal. A change of only folder or favorite goes through `/partial` before all of these and is not
revision-checked: it carries no item data (Risks). The pre-check keeps the guard in force after the
post-conflict sync has refreshed the store, and it rejects a save queued behind another save of the
same item (Save races).

**Detection.** HTTP 400 whose message contains "out of date" (case-insensitive) maps to
`VaultError.conflict` in `VaultRepositoryImpl`. One matcher function, both texts pinned in tests:
- Vaultwarden: "The client copy of this cipher is out of date. Resync the client and try again."
- Official server (source-reviewed, not tested): "The item cannot be saved because it is out of
  date. To edit this item, first sync your vault, or log out and back in."

The mapping wraps only the update `PUT /api/ciphers/{id}`. Answers to `/partial`, create and
`/collections` are not mapped, so an out-of-date answer to the collection update after a saved PUT
is a partial org save (below), not a conflict. Nothing is retried and the stored record is left as
it was. The official-server test fixture is hand-written from the source, not captured. This
mapping comes before the generic error text: since `server-error-texts`, any other server message
is shown verbatim. Logs record status and path only.

**Tolerance.** Vaultwarden truncates both times to whole seconds and rejects when the difference
is more than 1 s. So it always rejects a competing write that is 2 s or more newer than
`lastKnownRevisionDate`, never rejects one that is less than 1 s newer, and in between (1 s to
under 2 s) the answer depends on where the second boundary falls; the official server rejects
above 1 s. Edits made within about 2 s of each other may go undetected. Tests that simulate a
competing edit wait more than 2 s. Vaultwarden 1.37.4 rejected a gap of 3.05 s and accepted one of
20 ms (tested, "Server behavior" E5); the rule between them and the official server's 1 s are
source-reviewed, not tested.

**Revision refresh after Prizm's own changes.** After soft delete, restore, attachment add and
delete, collection change, favorite and folder (single and bulk move, and an edit that changes only
folder or favorite), Prizm stores the cipher the response carries, or fetches it with
`GET /api/ciphers/{id}` (`getCipher`, new) when the response has none.
- Responses that carry the cipher: restore (`restoreCipher` returns it instead of `Void`;
  Vaultwarden 1.37.4 tested 2026-10-28, `sha256:efb3cde9…`: Prizm made no fetch after a restore;
  the official server source-reviewed, not tested) and the collection update
  (`updateCipherCollections` returns it; Vaultwarden 1.37.4 answers with the cipher, tested, E7;
  the official server source-reviewed, not tested). An empty or unreadable body counts as none and
  leads to a fetch. Soft delete answers with an empty body and `/partial` with only `favorite` and
  `folderId` (both source-reviewed on Vaultwarden and the official server, not tested as captured
  answers; Prizm fetched the item after each on Vaultwarden 1.37.4, tested 2026-10-28), so both
  lead to a fetch. Attachment add and delete share one funnel, `updateAttachments`, which fetches.
- The fresh record replaces the stored one. The cached item's revision is patched with the fresh
  record's revision only when nothing the user sees has changed, which is decided from ciphertext,
  with nothing decrypted: (a) the fresh record's item content equals the record that was stored
  before the operation, and (b) the cached item's revision equalled that stored record's revision
  before the operation. Item content is every member of the record except `revisionDate`,
  `deletedDate`, `folderId`, `favorite`, `collectionIds`, `attachments` and the request-only members
  (`encryptedFor`, `lastKnownRevisionDate`); those are what Prizm's own operations change, or what
  the server changes on its own (Vaultwarden's soft delete and restore bump the revision and change
  nothing else). Otherwise another client changed the item after Prizm read it: the fresh record is
  stored, the cached revision stays, and the next save fails the local pre-check with
  `VaultError.conflict`, which a reload resolves. Moving the revision on would make that save look
  current and overwrite the other client's change. Condition (b) keeps a conflict that an earlier
  refresh left: a later refresh of the same content does not repair it. The rest of the cached item
  stays as the operation left it. A record for another item id is ignored and logged.
- Bulk moves refresh in the background, at most four fetches at a time, as the queue tail of every
  moved item (Save races): the move returns at once, and a later write to a moved item waits for
  that item's fetch.
- This runs for every one of these operations, whether or not it bumps the revision. `/partial`
  does not bump (Vaultwarden 1.37.4 tested, E7; official server source-reviewed, not tested); `PUT /collections` and
  attachment changes bump on the official server (source-reviewed, not tested) but not on
  Vaultwarden (Vaultwarden 1.37.4 tested, "Server behavior" E7). The measured matrix (E7) is
  recorded below as evidence, not used to skip refreshes.
- After an org save (`PUT /api/ciphers/{id}`, then `PUT /api/ciphers/{id}/collections`), the stored
  record and revision come from the collection update's answer (or a fetch after it), not from the
  PUT response.
- If the follow-up fetch fails, the operation still succeeds. The failure is logged at `.error`
  (ids only) and nothing is shown, because the user did not ask for the refresh. The worst case is
  a later false conflict, which is safe and costs one reload. A refresh that finishes after lock
  writes nothing.
- **Partial org save.** If the PUT succeeds and `PUT /collections` fails, the PUT answer is stored
  and cached with the collections it reports, the item is fetched again, the failure is logged, and
  the save throws `VaultError.collectionChangeNotSaved`, which carries no payload. The sheet shows a
  distinct error ("Your changes were saved, but the collection change failed. Try again."), stays
  open with the user's input, and the draft's base revision moves to the cached item's. The retry is
  a full PUT again, with the moved base, followed by the collection update. It passes the pre-check
  and the server's check, so it never reports a conflict with Prizm's own save; the cost is one
  extra revision bump. A retry that sends only the collection change is not built: it would be a
  second send path for one field.

**Save races.**
- `isSaving` is set synchronously in `save()`, before the task starts, so a double click sends one
  request.
- **Lock fence.** The `RawCipherStore` generation (D1) is a lock-protected counter that is read and
  compared synchronously (`currentGeneration()`, `isCurrent(_:)`, `invalidate()`), so no suspension
  point lies between the check and the write it guards. `clearVault()` invalidates it first.
  `update()` and `create()` read it before anything is awaited and check it after the request and
  again right before the answer is mapped and cached. A save that finishes after lock throws
  `VaultError.vaultLocked` with no store write, no decrypt, no cache write and no success callback;
  the lock has already closed the sheet, so nothing is shown, and the item id is logged at `.info`.
  After the next unlock, sync shows whatever the server holds. A sync hands the token it read at its
  start to `populate` (`VaultSessionToken`, a Domain type), and `populate` changes nothing when the
  token is stale, so a sync that finishes after lock cannot refill the item list either.
- **Per-item queue.** Writes to one item id run one after another in the order they were called,
  and none is rejected for waiting; writes to different items run in parallel. Queued: update, soft
  delete, restore, permanent delete (single and Empty Trash), favorite, single and bulk move (every
  id in it) and the attachment cache update. Not queued: create (a new id) and the folder and
  collection methods; the attachment upload and delete requests themselves run before the queued
  cache update. A save reads the store token when it is called, before it waits, so a save queued
  before a lock sends nothing. A queued edit-sheet save runs the pre-check against the record the
  write before it stored: a second save of an item after a first that went through is a conflict
  without a request.
- The edit sheet is window-modal, so in one window none of Prizm's own writes can reach the item
  while its sheet is open. Two windows are a known gap.

### D7. Conflict UX

- **Message:** "This item was changed on another device. Your changes were not saved. Reload to see
  the latest version, then make your changes again." It is shown in the edit sheet's existing error
  banner, with an inline "Discard my changes and reload" button and a sync status line ("Syncing…",
  "Synced", or the sync error). Design System tokens only.
- **VoiceOver:** the sheet announces what the banner shows: the displayed message (so the item-gone
  note too), "Synced" or the sync error but not "Syncing…", and "Reloaded the latest version." after
  each reload, which refills the fields without any visible event. This replaces the earlier
  announcement of every save error, which never saw the item-gone note. The message is announced at
  high priority and the status at low priority, through AppKit's announcement request: the sync
  often ends while the message is still being read, a later announcement at default priority cut it
  off, and macOS VoiceOver ignores the priority that SwiftUI's announcement carries (found in the
  hand check). The banner is one accessibility container with its icons hidden; the reload button
  (or Close) follows the message and comes before the status. While the sheet shows a conflict, the
  vault browser shows a sync error from the conflict sync in its banner but does not announce it,
  so it is spoken once.
- **Sync:** `ItemEditViewModel.onConflict` is wired in `PrizmApp.makeEditViewModel` to
  `VaultBrowserViewModel.resyncAfterConflict()`, which runs the injected `SyncUseCase`. The edit
  view model does not get the use case. A sync that is already running is not taken as the resync,
  because it may have read the server before the competing edit: on `SyncError.syncInProgress` the
  browser waits 500 ms and asks again, at most 20 attempts (about ten seconds), then reports "Sync
  is already in progress." as the sync error, which the user can retry with the reload button. A
  lock or sign-out during the resync drops its result. The edit sheet stays open while the sync
  refreshes the item list: `ItemDetailView` hosts it outside its selected-item branch, so a sync
  that replaces or removes the selected item does not close it.
- **Save stays blocked** until the user reloads. The block lives in the view model (`canSave`), so
  the toolbar button, ⌘S and Item > Save in the menu bar, which reaches the save without the button,
  are all blocked; Save keeps its title and has the hint "Reload the item first." Discard and Esc
  stay usable, also while "Syncing…" shows. Fields stay editable and copyable. No auto-retry, no
  rebase, and `clearDraft()` is not called.
- **Reload** replaces the draft and the original in place with the freshly synced item, so the user
  sees the other device's version and can re-apply the edit. It never refills from the copy the
  server rejected: if the sync failed, the first press starts a new sync and refills nothing, and a
  press after that sync has succeeded refills the sheet (two presses, as built and tested).
  The button is disabled while the sync runs and has no keyboard shortcut. No confirmation dialog;
  the label says the changes are discarded. A reloaded item that now has an edit block (D4) is
  refilled, and its Save shows the cannot-be-edited message.
- **Item gone** (deleted elsewhere, moved to the trash or access revoked): a trashed item counts as
  gone, because Prizm does not edit trashed items. The banner shows
  "This item is no longer available. It was deleted or moved on another device, or your access was removed."
  Save stays blocked, the reload button becomes Close, which closes the sheet without the discard
  alert, and Delete Item is hidden. Nothing is recreated.

**Live result.** Prizm with the conflict flow and the announcement change on Vaultwarden 1.37.4 (tested 2026-10-28, `sha256:efb3cde9…`, extension
2026.10.0 in Chrome). The twin's notes were changed in the extension at least 3 s after Prizm's
sync. Prizm's save of a new name for the twin was then rejected with 400 and showed the banner,
"Syncing…" and "Synced"; the extension still showed its own notes; "Discard my changes and reload"
showed the extension's notes, and the next save succeeded. The keyless control was moved to the
trash, restored and edited, then given a text file as an attachment and edited, then starred and
edited; the org login was edited twice in a row. Each of these edits saved without a conflict. A
secure note was created. After a lock and unlock in Prizm and a sync in the extension, every edit
was there, and the extension listed the control under its favorites. The captured request bodies show
the server's six-digit revision as `lastKnownRevisionDate` in every Prizm PUT: the rejected twin PUT
carried the revision Prizm had synced and the accepted one the extension's; the control's revisions
increase from PUT to PUT, and each of its edits was preceded by a fetch of the item; no PUT carried
a 1970 revision, and the create carried none. The extension could not download the attachment Prizm
added (Known gaps).

## Server behavior

Each row says where the fact comes from: "tested" (Vaultwarden on a test server, image digest
and date given) or "source-reviewed, not tested". Bitwarden self-hosted was not available for
testing. The Vaultwarden cells were filled from tasks 1.2–1.5.

**Test server provenance:**

- `vaultwarden/server:1.37.4@sha256:efb3cde962015fcc036b2ea625242248611943b27212ebf4392841fb30fad055`:
  `GET /api/version` 1.37.4, `/api/config` version 2026.6.0, gitHash `7c188967`. The server was started from
  this digest; the running server's digest was not read back, only the version and gitHash
  above.
- `vaultwarden/server:1.37.3@sha256:1587c45feaa479f1f5e8af3b00eded36bff77bcf1880cf8dbf0541706dd470e0`:
  `GET /api/version` 1.37.3, `/api/config` version 2026.6.0, gitHash `eb212e23`.
- Fixture authored on 1.37.3 on 2026-10-26: the unkeyed control and twin in the web vault v2026.7.0
  with the flag off, never saved by a client afterwards; the other items with the Bitwarden browser
  extension 2026.10.0 in Chrome (version read once on `chrome://extensions`, before and after
  authoring; Chrome version not reported; the unpacked `bitwarden/clients` release build
  `browser-v2026.10.0`, which Chrome does not update automatically) with the
  `cipher-key-encryption` flag present in the server's `/api/config` answer.
- Captured on 1.37.4 on 2026-10-26, after restoring the authored data into it. The E0 and E1
  checks used Prizm as it was before this change (the code of the PR base); E1 to E9
  were sent as raw requests on 2026-10-26, and the client checks were made on 2026-10-27 with
  extension 2026.10.0 in Chrome.
- Fixture files: `PrizmTests/Fixtures/sync-golden-1.37.4.json` and
  `PrizmTests/Fixtures/stale-put-400-1.37.4.json`, described in `PrizmTests/Fixtures/README.md`.

| # | Question | Vaultwarden 1.37.4 | Vaultwarden 1.37.3 | Official server |
|---|---|---|---|---|
| E0 | Does a keyed item made by the extension load in today's Prizm? | The two unkeyed items (control and twin) are listed and readable; the four keyed items (passkey login, archived, SSH key, org login) are missing, with no error shown (tested 2026-10-26, `sha256:efb3cde9…`, Prizm before this change). That the drop is a MAC failure counted as a failed cipher is source-reviewed, not tested: the log stream was not captured | not run (E0 runs on 1.37.4) | n/a (client-side) |
| E1 | Create and update without `encryptedFor` | 422, Rocket's generic body (tested 2026-10-26, `sha256:efb3cde9…`) | accepted (tested 2026-10-26, `sha256:1587c45f…`) | accepted, field optional (source-reviewed, not tested) |
| E1b | Update with `encryptedFor` = own id | 200; a create with it also 200, with a random id 422 "Invalid user cipher" (tested 2026-10-26, `sha256:efb3cde9…`) | 200; a create with a random id also 200, so the field is ignored (tested 2026-10-26, `sha256:1587c45f…`) | accepted (source-reviewed, not tested) |
| E2 | Update with `key` omitted on a keyed item | (i) `key` cleared, field ciphertexts and the attachment row unchanged (tested 2026-10-26, `sha256:efb3cde9…`); the web vault then cannot decrypt the item and logs a decrypt failure for it and for its attachment (tested 2026-10-27, `sha256:efb3cde9…`, extension 2026.10.0 in Chrome; extension view not reported separately). That echo keeps the fields encrypted with the item key; a Prizm update re-encrypts them with the vault key, so only the attachment is expected to fail (source-reviewed, not tested). (ii) A Prizm-shaped update cleared `key`, `fido2Credentials`, `passwordRevisionDate` and the `uriChecksum` values and emptied `passwordHistory`; `autofillOnPageLoad` was already null (tested 2026-10-26, `sha256:efb3cde9…`); the item opens in the web vault and the extension, showing the twin's values because the test body borrows the twin's ciphertext, without passkey or password history (tested 2026-10-27, `sha256:efb3cde9…`, extension 2026.10.0 in Chrome) | not run | `key` cleared (source-reviewed, not tested) |
| E3 | Flag `cipher-key-encryption` present in the `/api/config` answer; extension creates a keyed item | not run (authoring is on 1.37.3) | The flag was present exactly once in the `/api/config` answer; the extension then created keyed items: `key` set (a `2.` EncString) on 4 of 6 items, null on the 2 controls made with the flag off (tested 2026-10-26, `sha256:1587c45f…`, extension 2026.10.0 in Chrome) | n/a |
| E4 | Update without `archivedDate` on an archived item | Un-archived: the update returns 200 and the item is no longer archived on the server (tested 2026-10-26, `sha256:efb3cde9…`); the client shows it in the normal vault and the database has no archive row (tested 2026-10-27, `sha256:efb3cde9…`, extension 2026.10.0 in Chrome) | Un-archived: the update returns 200 and the item is no longer archived on the server (tested 2026-10-26, `sha256:1587c45f…`); the client shows it in the normal vault and the database has no archive row (tested 2026-10-27, `sha256:1587c45f…`, extension 2026.10.0 in Chrome) | un-archived (source-reviewed, not tested) |
| E5 | Update with an old `lastKnownRevisionDate` after a competing edit ≥ 2 s later | Gap 3.05 s: 400 "The client copy of this cipher is out of date. Resync the client and try again.", and the stored item stayed as the competing write left it (body saved as `PrizmTests/Fixtures/stale-put-400-1.37.4.json`). Gap 20 ms: accepted (200), the competing write is overwritten. `lastKnownRevisionDate` of 1970-01-01T00:00:00.000Z: 400. `not-a-date`: accepted (200), so the check is skipped. Gaps between 20 ms and 3.05 s were not measured (tested 2026-10-26, `sha256:efb3cde9…`) | Gap 3.05 s: 400 with the same message, stored item unchanged (tested 2026-10-26, `sha256:1587c45f…`) | 400 with the official text (source-reviewed, not tested) |
| E6 | Timestamp shapes the server emits | `revisionDate`, `creationDate`, `archivedDate`, `login.passwordRevisionDate` and `passwordHistory[].lastUsedDate`: `YYYY-MM-DDTHH:MM:SS.ffffffZ` (six fractional digits, `Z`). `login.fido2Credentials[].creationDate`: `YYYY-MM-DDTHH:MM:SS.fffZ` (three digits, the client's own format kept). (tested 2026-10-26, `sha256:efb3cde9…`, golden fixture). `deletedDate`: `YYYY-MM-DDTHH:MM:SS.ffffffZ` (six fractional digits, `Z`), the same in `GET /api/ciphers/<id>` and `/api/sync`; the golden fixture has no trashed item, so this was read from a soft-deleted throwaway clone (tested 2026-10-27, `sha256:efb3cde9…`) | not run (this row runs on 1.37.4 only) | not reviewed |
| E7 | Which operations bump `revisionDate` | Bump: full update, soft delete, restore. No bump: `/partial` favorite and folder, bulk move (`PUT /api/ciphers/move`), archive, unarchive, attachment create, upload and delete, `PUT /collections` on an org item (its response carries `revisionDate`, unchanged) (tested 2026-10-26, `sha256:efb3cde9…`) | not run | `/partial`: no bump; `/collections` and attachments: bump (source-reviewed, not tested) |
| E8 | Update of an SSH item without `keyFingerprint` | `sshKey` is `null` afterwards: private key, public key and fingerprint are all gone (tested 2026-10-26, `sha256:efb3cde9…`) | not run | stored without fingerprint (source-reviewed, not tested) |
| E9 | Extension opens a keyed item with a wrong `uriChecksum` | The update with the first two `uriChecksum` values swapped is accepted (200) and stored (tested 2026-10-26, `sha256:efb3cde9…`); the client shows no URIs at all, while the unmodified original shows two. Both URIs carry a wrong checksum after the swap, so both are hidden (tested 2026-10-27, `sha256:efb3cde9…`, extension 2026.10.0 in Chrome) | not run | n/a (client-side) |

**D0 blocker status:** yes. Today's Prizm lists the two unkeyed items and silently drops all four keyed ones, with no error shown (tested 2026-10-26, `sha256:efb3cde9…`, Prizm before this change). D0 ships either way (D0 above).

**Live verification:** a table with one row per manual check (pass or fail, date, Vaultwarden
digest, the client that made the competing edits, the tree hash of `Prizm/` that was tested) is
added when the change is archived; task 5.4 lists the checks and their results.

## Risks / Trade-offs

- **[Low] A star or folder set through `/partial` elsewhere can be undone by a Prizm edit.**
  `/partial` changes do not bump the cipher's revision (Vaultwarden tested, official server source-reviewed), so `lastKnownRevisionDate`
  cannot detect them. Such changes come from Prizm on another Mac, or from official clients on
  read-only items (they star editable items with a full PUT, which bumps the revision and is
  detected). A full edit sends the favorite and folder from the edit sheet and silently resets such
  a change made after Prizm's last sync. Same class as the known gap in
  `favorite-toggle-serialisation` (a folder-only save can undo a star clicked just before).
  → Open Question 2.
- **[Low] An archive or unarchive made elsewhere can be undone by a Prizm edit.** Archive and
  unarchive do not bump the cipher's revision (Vaultwarden 1.37.4 tested, E7), so
  `lastKnownRevisionDate` cannot detect them (D6). A Prizm edit after such a change, made since
  Prizm's last sync, sends the stored `archivedDate` back and silently reverts it. Same class as
  the `/partial` item above.
- **[Medium] Server differences are only partly tested.** Only Vaultwarden is available. Official
  server rows are source-reviewed; the PR says "verified against Vaultwarden 1.37.4".
- **[Medium] Store lifecycle.** A stale or missing record would make a save fail closed, not lose
  data. The store is rebuilt wholesale on every sync, cleared in `clearVault()` with a generation
  token, and shared by one instance (tested: sync followed by update on the same store; lock and
  sign-out empty it; a sync running at lock does not refill it). A sync that lands between a save's
  read of the record and its PUT is safe: the server's revision check rejects the PUT if the item
  changed, and the stored record is replaced by the PUT response afterwards. A sync that finishes
  after the clear writes nothing that outlives its session: the store, the profile id and the key
  caches are all guarded by the token the sync read at its start, which also tells it from the
  sync of a session that followed (a lock plus an unlock passes an "is unlocked" check). The one
  gap left is a lock that lands inside a single actor hop between a key-cache check and its write.
- **[Low] False conflicts** if a refresh `GET` fails after one of Prizm's own changes. Logged; the
  user reloads once.
- **[Low] A refresh that finds another client's change leaves the conflict to the next save.** After
  Prizm's own change (a star, a move, a soft delete) the item still shows what the user last saw,
  and the first save after it fails with the conflict message instead of overwriting the other
  client's change; a reload shows that version. The comparison is on ciphertext and ignores the
  members in D6, so a favorite, folder or collection change made elsewhere is not content and is
  not detected here (the first Risk above is the same class).
- **[Low] A late answer can store an older record.** A refresh answer that arrives after a newer
  sync, or a sync that read the server before a save that finished first, can leave the stored
  record and the cached item one revision behind the server. Neither is ordered against the other.
  The next edit of that item then conflicts once, and a reload fixes it; nothing is overwritten.
- **[Low] An update whose answer cannot be read leaves the stored record unrefreshed.** The server
  has applied the save, but Prizm cannot read the new revision from the answer, so it keeps the
  old record. The retry passes Prizm's own check and goes out with the old revision; the server
  holds the first save and can answer "out of date" once. One reload recovers. Avoiding this needs a
  new error type and user-facing text, so it is left as it is.
- **[Low] Items already damaged by the bug** cannot be repaired: the data is gone from the server.
  → The CHANGELOG says so plainly. Users can restore passkeys from another device's Bitwarden
  export if they still have one.
- **Related fix already done.** The sign-out gap where `orgKeyCache` was not cleared was fixed by
  `harden-key-lifecycle-and-logging` (sign-out runs the lock teardown). The new store does not rely
  on it; it is cleared in `clearVault()`.

## Known gaps

- **Bitwarden self-hosted not tested.** Every official-server statement here is source-reviewed.
- **Password history is preserved but not appended** (a possible follow-up change,
  `password-history`).
- **Prizm's version header bypasses the official passkey edit gate.** The official server refuses to
  edit a login with passkeys from clients older than 2023.10.0. Prizm declares 2024.12.0, so the
  gate never protects passkeys from Prizm; this change is what protects them. Changing the declared
  version is rejected (it would misreport the client). Vaultwarden has no such gate (both server
  statements source-reviewed, not tested).
- **Blob and V2 (COSE) ciphers** are refused for editing (D4), not supported.
- **One undecodable cipher aborts the whole sync.** Fault-tolerant per-item decode is a follow-up.
- **Item types 6–8.** Vaultwarden 1.37.4 sends them to every client; Prizm cannot map them. The
  official server hides them from Prizm's declared version (both source-reviewed, not tested).
- **Dropped on read today:** custom fields without a name and URI entries without a value. They are
  not shown, so a save removes them (D3).
- **SSH key text edits** keep the old fingerprint; a possible follow-up change,
  `fix-ssh-key-roundtrip`, would cover this.
- **Items whose name is a legacy EncString without MAC (type 0) cannot be edited.** Edit is
  disabled with the reason `legacyEncryption` (D4), and the key check (D2) would refuse them too,
  until a possible follow-up change, `fix-encstring-validation`, refuses type 0 everywhere. Such names are a deprecated, rare
  format. An item whose own key is type 0 is not listed at all (D0).
- **SSH items without key data are read-only.** An SSH item that an earlier Prizm save left with
  `sshKey: null` (E8) has nothing to rebuild from and is blocked as `unmappable` (D4). Restoring its
  key is out of reach: the server no longer has it.
- **Attachments written by official clients do not open in Prizm** (out of scope, older than this
  change). Official clients store a file as `0x02 ‖ IV ‖ MAC ‖ ciphertext`; Prizm reads
  `IV ‖ ciphertext ‖ MAC`, so the MAC check fails and Prizm shows "Could not open file". Seen in the
  live check of D2 on the fixture's passkey login: Prizm's error came from the file's MAC check,
  after the attachment key had unwrapped under the item key, and the file was unchanged on the
  server and downloaded in the extension. A later "save file" in the same session failed with
  "Server error 404". That is likely Prizm reusing the download link from the last sync after the
  server let it expire; attachment requests were not captured, so the 404 is recorded as Prizm
  reported it. Possible follow-up changes would cover them: `fix-attachment-file-format` (file
  layout) and `fix-attachment-transfer-flow` (fresh download link). Until the file layout is
  fixed, the scenario "Editing an item with its own key and an attachment" claims only that the
  attachment record, its key and its file stay intact on the server, and task 5.4 adds that a
  second client downloads, authenticates and decrypts a file an official client wrote; neither
  claims that Prizm opens it. The other direction fails as
  well: a text file Prizm attached to the control in the live check of D7 (2026-10-28) could not be downloaded in
  the extension. That matches the same layout difference; attachment requests were not captured,
  so it was not analysed further.
- **Two main windows can produce a real conflict for Prizm's own changes.** New Window opens a
  second main window that shares the vault browser. A soft delete, restore or attachment change of
  an item that is open in the other window's edit sheet can move the item's revision (soft delete
  and restore on Vaultwarden 1.37.4, tested, E7; attachment changes on the official server,
  source-reviewed, not tested), so that sheet's save
  is rejected as a conflict and recovered by reload. There is no cross-window guard. In one window
  the sheet is modal, so this cannot happen.
- **Folder and collection deletes on the official server** may change the revision of the ciphers
  in them. This was not reviewed in the server source or tested. Prizm does not refresh those
  ciphers, so the worst case is one conflict and a reload.
- **The disabled Edit button of a blocked item showed no hover help and could not be reached with
  the keyboard** (observed by hand, 2026-10-27). The note in the detail pane shows the same
  message, so the reason is visible without the button. That VoiceOver reads the hint on the
  disabled button was not confirmed by hand, and the final live check did not cover it; the
  requirement therefore says only that the button carries the hint and the pane shows the note.

## Open Questions

1. ~~Should Prizm append to `passwordHistory` on password change in this fix?~~ Resolved: no,
   left to a possible follow-up change, `password-history` (see D3).
2. Should a full edit leave favorite and folder alone when the user did not change them (send the
   values from the last sync instead of the edit sheet), so a star set on another device survives?
   Official clients send the edit form's values as well.
