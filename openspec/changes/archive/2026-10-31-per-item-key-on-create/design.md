# Design

## Context

**What official clients send on create.** Source: Bitwarden SDK, `sdk-internal` at 2026-10-23,
`crates/bitwarden-vault/src/cipher/cipher.rs`.

- `CipherView::load_cipher_key_slot` returns the item's key, or generates a new symmetric key when
  the item has none. Its doc comment: "Every cipher the SDK encrypts carries its own key."
- The encrypted `Cipher` gets `key: Some(ctx.wrap_symmetric_key(key, ciphers_key))`. The wrapping
  key is the item's key identifier: the user key for personal items, the org key for org items.
- Every field (name, notes, login incl. URIs and checksums, card, identity, SSH key, custom fields,
  password history, attachment keys) is encrypted with the item's key, not the wrapping key.
- Before sdk-internal commit `095bfda` (2026-10-05) this was gated by the client flag
  `enable_cipher_key_encryption`. Browser extension 2026.10.0 still ships the older SDK (build 1075)
  and the flag. Neither that release nor the iOS app checks a minimum server version for it.

**Server side.** Both servers store `key` from the create request as sent:
- Official: `CipherRequestModel.Key` → `Cipher.Key`.
- Vaultwarden 1.37.4: `cipher.key = data.key` (`src/api/core/ciphers.rs`).

Personal items are created with `POST /api/ciphers`, org items with `POST /api/ciphers/create`.

**Prizm today** (`origin/develop` beb861ff).
- `VaultRepositoryImpl.create` picks the org key or the vault key (`encryptionKeys`, no fallback for
  a missing org key), then calls `CipherMapper.toNewRawCipher(_:encryptedWith:encryptedFor:)`, which
  sends `key: nil`.
- It maps the server's answer with `CipherMapper.map`, which resolves the item's own key from the
  answer's `key` (`effectiveKeys`), and records `.of(createdRaw, effectiveKey:)` in `VaultKeyCache`
  (`fix-org-attachment-key`). `VaultKeyServiceImpl` has no vault-key fallback any more.
- `AttachmentCrypto.generateAttachmentKey()` produces 64 random bytes with `SecRandomCopyBytes`.
  Wrapping 64 bytes as a type-2 EncString is `EncString.encrypt(data:keys:)`.
- `toNewRawCipher` is also used to build server records of items without their own key for the UI
  test vault (`App/UITestFixtures.swift`) and many unit tests.

## Goals / Non-Goals

**Goals**
- An item created in Prizm cannot be told apart from one created by an official client, as far as
  key structure goes.
- No new cryptographic algorithm. Only the existing random source and EncString type 2 are reused.
- No path where a new item ends up encrypted with one key and cached with another.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Generate a 64-byte item key with the existing random source

`SecRandomCopyBytes`, 64 bytes, split into a 32-byte AES-256 key and a 32-byte HMAC-SHA256 key, the
same layout as attachment keys and the vault key. `generateAttachmentKey()` is renamed
`generateSymmetricKey()`, so attachment and item keys share one audited function.

Zeroing, exactly: the generator zeroes its `[UInt8]` buffer after copying it into the returned
`Data`, and `create()` zeroes that 64-byte `Data` (`defer resetBytes`) once the request is built and
the answer checked. The two halves of the `CryptoKeys` built from it are zeroed the same way (security
review 2026-10-31). Copies inside CommonCrypto and `EncString` are not reachable (best effort); the
copy in `VaultKeyCache` is cleared on lock with the rest of the cache.

A generation or wrapping failure is mapped to `VaultError.itemKeyGenerationFailed` with a
user-facing text; nothing is sent.

### D2. Wrap with the vault key or the org key as EncString type 2

Same function and format as attachment-key wrapping: AES-256-CBC + HMAC-SHA256, encrypt-then-MAC,
`2.<iv>|<ct>|<mac>`. The wrapping key is the org key for an org item and the vault key otherwise. If
the org key is missing, the save fails (no fallback to the vault key). This is the rule
`fix-org-key-required-on-write` introduced for create and update; `fix-cipher-edit-data-loss`
keeps it for edits.

### D3. Encrypt every field with the item key

A new `toNewKeyedRawCipher(_:itemKey:wrappedWith:encryptedFor:)` wraps the item key and builds the
request through the same code as `toNewRawCipher`, with the item key as the encryption key and the
wrapped key as `key`. That includes `uriChecksum` and custom fields. `create()` uses only this
entry point. `toNewRawCipher` stays for records of items without their own key (the UI-test vault
and unit tests); it is renamed `toUnkeyedRawCipher` and documented as never a create path, so a
later create path cannot pick it up by accident. A test asserts that `create()` never sends a
request without `key`.

Every create goes through `CreateVaultItemUseCaseImpl` → `VaultRepositoryImpl.create`, the SSH key
generation and import included; Prizm has no clone or import path. The create body therefore carries `key`, `encryptedFor` (from
`fix-cipher-edit-data-loss`) and fields that only decrypt with the item key.

### D4. Check the answer's key, then use the existing cache write

Since `fix-org-attachment-key`, `create()` maps the server's answer and records its key source and
effective key in `VaultKeyCache`; `VaultKeyServiceImpl` refuses a cipher it does not know.

New: before the answer is stored, mapped or cached, `create()` checks that the answer's `key`
unwraps under the wrapping key to exactly the generated bytes and that its `organizationId` is the
one Prizm sent; then it maps the answer, still before storing it. If `key` is missing, does not
unwrap or differs, the organization differs, or the answer does not map (a field fails its MAC):
- the item exists on the server, but Prizm cannot trust its answer, so nothing is stored, cached or
  added to the list; `.error` log with the cipher id only;
- `create()` throws `VaultError.createdButUnconfirmed` ("Saved, but Prizm couldn't confirm the new
  item. Sync to see it.");
- the create sheet shows that text, keeps Save disabled (a second Save would create a duplicate)
  and closes with Discard or Esc. The next sync lists the item through its `key`.

So the key in the cache is always both the generated key and the one in the answer.

A lock between send and record discards the generated key: the existing generation checks drop the
store and cache writes, and the next unlock's sync reads the item through its `key`.

### D5. No server-version gate

Current official clients (SDK after `095bfda`, iOS) don't gate this on the server version, and both
target servers store `key`. Prizm follows them. Every server where create works today stores `key`
too: Vaultwarden 1.32.0 (`git show 1.32.0:src/api/core/ciphers.rs`, `:214`, `cipher.key = data.key`
at `:493`) and the official server from at least v2023.10.0 (`CipherRequestModel.cs:21,90`). So no
legacy path is needed. Task 5.1 confirms both create endpoints on the rig; the code does not check
versions.

**Rejected alternative:** key new items only when `/api/config` advertises `cipher-key-encryption`.
Vaultwarden never sends that flag, and the SDK no longer reads it, so Prizm would never key items on
Vaultwarden.

## Risks / Trade-offs

- **[Medium] Key confusion on the write path.** A field encrypted with the wrong key makes the item
  unreadable everywhere. → Tests decrypt the request body independently: the key is unwrapped with
  the vault or org key, then every field is decrypted with the item key. An interop check reads the
  item in an official client.
- **[Low] Older official clients** that predate cipher key encryption cannot read keyed items.
  Official clients read item keys since 2024.2.0, the version Vaultwarden's `/api/config` names for
  individual cipher key encryption (`src/api/core/mod.rs:228-230`, task 1.1). Items keyed by
  official clients already exist in the same vaults.
- **[Low] Cache and response disagree.** → D4 checks the answer before anything is cached, so the
  cached key is both.

## Open Questions

1. Should a follow-up change add a key to existing unkeyed items on edit, as the SDK does? Deferred:
   it requires re-encrypting fields that `fix-cipher-edit-data-loss` keeps opaque (see proposal.md,
   Non-Goals).

## Review

- Spec challenge (fresh agent, before code): 11 findings, all adopted (answer key check →
  `createdButUnconfirmed`, `itemKeyGenerationFailed`, `toNewRawCipher` renamed `toUnkeyedRawCipher`).
- Code review (fresh agent, 2026-10-31): 0 high/medium, 4 low; R1–R3 fixed (red 20261031T074813Z,
  green 20261031T074829Z), R4 by rewording task 4.1.
- Security review (fresh agent, 2026-10-31): 0 high/medium, 2 low, both fixed. LOW-1: an answer with
  the right key but another organization, or with a field that fails its MAC, was stored before it
  was mapped and left Save enabled, so a second Save duplicated the item; now the organization is
  checked and the answer mapped before anything is stored, and either failure gives
  `createdButUnconfirmed`. LOW-2: the item key halves are zeroed after use (red 20261031T171001Z,
  green 20261031T171045Z).
- `/opsx:verify` (2026-10-31): 0 critical, 0 warnings, 4 suggestions; org-create-answered-as-personal
  test and a comment at the `EncStringError` mapping added (green 20261031T180640Z), the others are
  task evidence.
- Rig (Vaultwarden 1.37.4, `bw` 2026.9.1): a personal and an organization item created by Prizm,
  each with an attachment and no sync in between, carry a key; `bw` reads them and their
  attachments, edits them, and Prizm reads the edits (20261031T171553Z, 20261031T171658Z).
