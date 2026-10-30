# Design

## Context

**Official layout.** Sources: sdk-internal and clients at HEAD 2026-10-23.

- SDK `crates/bitwarden-crypto/src/enc_string/symmetric.rs:207-238` (`from_buffer`) and `:241-265`
  (`to_buffer`). Type 2 (`AES256_CBC_HMAC_TYPE`) is `type(1) ‖ IV(16) ‖ MAC(32) ‖ data`, minimum
  length 50. Type 0 is `type(1) ‖ IV(16) ‖ data`. Any other type byte is a parse error.
- TS `clients/libs/legacy-crypto/src/models/enc-array-buffer.ts:7-52`: the same layout. Minimum
  length for type 2 is `1 + 16 + 32 + 1`.
- The MAC is HMAC-SHA256 over `IV ‖ data`, the same as EncString type 2.
- **Type 0 is not decrypted by official clients.** SDK `symmetric.rs:479-485` returns
  `DecryptionNotImplementedForKey` for type 0. TS `encrypt.service.implementation.ts:70-75`
  (`decryptFileData`) throws "Decryption of AesCbc256_B64 encrypted data is disabled." The audit row
  A-01 says type 0 is "accepted for legacy blobs". That is wrong for current clients.
- Files are encrypted with `PureCrypto.symmetric_encrypt_filedata` (`encrypt.service.implementation.ts:45-48`),
  and the request carries `fileSize: encData.buffer.byteLength`, the encrypted length
  (`clients/libs/common/src/vault/services/cipher.service.ts:889`).
- Known-answer vector: SDK `crates/bitwarden-wasm-internal/src/pure_crypto.rs:396-411`, a 64-byte
  `KEY` and a 65-byte `ENCRYPTED_BYTES` that decrypts to `"test"` (test at `:487-491`).
- Upgrading an attachment: SDK `attachment_client/upgrade.rs:68-75` ("Downloads and re-encrypts the
  attachment, creates a new slot, uploads the new bytes, then deletes the old attachment. If the
  upload fails, it tries to delete the new slot").

**Sizes reported by the servers.** The `size` in sync is the stored encrypted length:
- Vaultwarden 1.37.4 stores the size the client declares on `attachment/v2`, then replaces it with
  the actual uploaded size (`src/api/core/ciphers.rs:1334`).
- Bitwarden server replaces it with the real blob size after validation
  (`src/Core/Vault/Services/Implementations/CipherService.cs:381-383`).
- Checked on the rig (Vaultwarden 1.37.4, run 2026-10-30, task 1.2): a file uploaded with the
  official `bw` CLI 2026.9.1 (it encrypts with the same SDK as the browser extension) syncs with
  size 3057 (mod 16 = 1); a file uploaded in the Prizm 1.5.0 layout syncs with size 2560 (mod 16 = 0).
  Bitwarden self-hosted was not checked (no rig for it); its server code above stores the real
  blob size the same way.

**Prizm today.**
- `AttachmentCrypto.swift:89-110` writes `IV ‖ ciphertext ‖ MAC`. `:132-157` reads only that,
  with a 49-byte minimum.
- `AttachmentRepositoryImpl.swift:104` declares `fileSize: encBlob.count` (encrypted length, as
  official). The locally built `Attachment` after upload uses the plaintext size
  (`AttachmentRepositoryImpl.swift:131`) until the next sync, or until the server's answer replaces
  it (`fix-attachment-transfer-flow`, D5).
- In the same stack: `fix-attachment-transfer-flow` (rollback of a failed upload, fresh download
  URL, item record from the server's answers) and `fix-org-attachment-key` (the effective key;
  org attachments wrapped with the personal key are flagged `wrappedWithPersonalKey` and open with
  that key).
- Attachments shipped in v1.1.0 (2026-04-09). Every release since writes the Prizm layout.

## Goals / Non-Goals

**Goals**
- Files uploaded by Prizm open in every official client, and the other way round.
- Files Prizm uploaded in the old layout stay readable in Prizm, and users can convert them.
- Layout detection is unambiguous and never depends on trial decryption.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Write type 2 in the official layout

`encryptData` returns `[0x02] + IV + MAC + ciphertext`. Algorithm, key split (32 bytes AES, 32
bytes MAC) and the random IV source are unchanged. A known-answer test decrypts the SDK vector,
and a structural test checks that Prizm's own output parses with the SDK rules (type byte, minimum
length, offsets).

### D2. Read by structure: length modulo 16, then type byte, then MAC

AES-CBC with PKCS#7 always produces a ciphertext that is a positive multiple of 16 bytes. So:

| Layout | Length L | `L mod 16` | Byte 0 |
|---|---|---|---|
| Official type 2 | `49 + 16k`, k ≥ 1 | 1 | `0x02` |
| Official type 0 | `17 + 16k`, k ≥ 1 | 1 | `0x00` |
| Old Prizm | `48 + 16k`, k ≥ 1 | 0 | random (first IV byte) |

`decryptData`:
1. `L mod 16 == 1` and byte 0 is `0x02`: official type 2 (`L < 65` throws `malformedBlob`).
2. `L mod 16 == 1` and any other byte 0 (`0x00` included): throw `unsupportedEncryptionType`
   (official clients refuse type 0 too).
3. `L mod 16 == 0` and `L ≥ 64`: old Prizm layout. Log at `.info` that a legacy blob was read.
4. Anything else: throw `malformedBlob`.

Then verify the MAC over `IV ‖ ciphertext` before decrypting, as today. The two valid layouts
have disjoint lengths, so detection is unambiguous. The MAC confirms it: a blob that parses as one
layout but was written in the other fails the MAC.

**Rejected alternative:** detect by byte 0 alone. An old Prizm blob starts with a random IV byte,
so about 1 in 256 old files would start with `0x02` and be parsed as the official layout.

**Rejected alternative:** try one layout, and on MAC failure try the other. It works, but it
computes two HMACs over files of up to 500 MB, and a plain wrong-key error looks like a layout
problem in the logs.

### D3. Find old files from the encrypted size, without downloading

Both servers report the actual encrypted size. An old Prizm file has `size mod 16 == 0`. No
official file can (table in D2). `AttachmentMapper` sets
`Attachment.storedInLegacyPrizmFormat = (size % 16 == 0)`. An attachment Prizm builds locally after
its own upload is in the official layout and is not flagged. This flag is a hint for the UI. The
real check is D2 at download time. If the hint is wrong (for example a server that reports another
size), conversion stops after the download with a clear error and changes nothing.

Task 1.2 confirmed the reported sizes on Vaultwarden 1.37.4; Bitwarden self-hosted was not
checked (Context).

### D4. Convert by re-uploading, like the SDK's `upgrade_attachment`

`ConvertAttachmentUseCase.execute(cipherId:attachment:)`, backed by
`AttachmentRepository.convertLegacyFormat(cipherId:attachment:downloadKey:uploadKey:)`:
1. Download with a fresh URL (`fix-attachment-transfer-flow`, D2), unwrap the attachment key with
   the key it was wrapped with: the personal key for an attachment flagged
   `wrappedWithPersonalKey`, otherwise the item's effective key (`VaultKeyService`, both from
   `fix-org-attachment-key`).
2. Check that the blob really was the old layout (D2 case 3). Otherwise stop: "This file is already
   in the standard format." A flagged attachment is converted in either layout, because its key
   still has to move to the organization key.
3. Upload the plaintext as a new attachment with the same file name, through the normal upload
   path: new 64-byte attachment key, official layout, file name and key wrapped with the effective
   key.
4. If the upload fails, the upload path deletes the new attachment record (rollback,
   `fix-attachment-transfer-flow` D1) and the old one stays.
5. Delete the old attachment. If that fails, the item has two copies. Prizm shows both and reports
   "Converted, but the old copy could not be removed. Delete it from the item."
6. Zero the plaintext and the attachment key. The cache is patched from the server's answers by
   the upload and delete paths.

Why a new key: the SDK does the same, and it keeps the conversion on the one audited upload path.

**Rejected alternative:** overwrite the file under the same attachment ID. Neither server documents
replacing the bytes of an existing attachment. Vaultwarden compares the new size with the stored
one (`ciphers.rs:1320-1340`). It would be a Prizm-only use of the API.

**Rejected alternative:** convert automatically during sync. It writes to the server without the
user's knowledge, can use a lot of bandwidth, and changes attachment IDs that other clients see.

### D5. User flow

- After a sync, if items not in the trash have old-layout attachments or attachments flagged
  `wrappedWithPersonalKey`, Prizm shows a one-time notice per unlock (items the user can only view
  are included until `honour-org-item-permissions`, see below): "N attachments were saved by an
  earlier Prizm version and can't be opened in other Bitwarden apps." Buttons: "Convert all" and "Later".
- Each such attachment row shows a small "Prizm format" badge and a "Convert" action. VoiceOver
  label: "Saved in old Prizm format. Other Bitwarden apps can't open it." A row flagged
  `wrappedWithPersonalKey` shows its "Only you can open this file" note and the same action.
- "Convert all" runs one file at a time with progress (`n of N`), can be cancelled between files,
  and lists failures at the end. The notice, progress and failures are one sheet over the vault
  browser, owned by `AttachmentConversionViewModel`.
- Items the user can only view: Prizm does not decode per-item permissions yet
  (`honour-org-item-permissions` adds `edit`). Until then the action is offered on every such
  attachment; a server that refuses answers with a message, which Prizm shows, and nothing is
  changed (the upload is refused before any record exists, or rolled back). Hiding the action and
  showing "Ask someone who can edit this item to convert it in Prizm." moves to
  `honour-org-item-permissions`.

### D6. Release and communication

- CHANGELOG **Fixed**: "Attachments now use the standard Bitwarden file format. Files uploaded with
  Prizm 1.1.0 to 1.5.x could not be opened in other Bitwarden apps; Prizm can convert them."
- Release notes, top section: which versions wrote the old format, and how to use "Convert all".
- README "Known Limitations": remove nothing; add a short note about converting old files until the
  next minor release.
- Before release, the maintainer decides whether to also open a GitHub issue or advisory. Upstream
  contact needs Christian's go-ahead (local rule).

## Risks / Trade-offs

- **[Medium] Conversion of org items with the wrong key.** → Hard dependency on
  `fix-org-attachment-key`. A test converts an org attachment and decrypts the new key with the
  org key.
- **[Low] Partial conversion** (new uploaded, old not deleted). → Both copies stay visible; the
  user deletes the old one. No data is lost.
- **[Low] Plaintext in memory** for the duration of one conversion, up to 500 MB. Same as download
  and upload today. Zeroed afterwards.
- **[Low] Size hint wrong** on a server that reports other sizes. → D2 is the real check; nothing
  is changed when the hint is wrong.

## Open Questions

1. Should Prizm keep reading the old layout forever, or remove it in a later major version? This
   design keeps it; the read path is small and covered by tests.
2. Does any server or proxy report a size other than the stored encrypted length (task 1.2)?
3. Should the maintainer warn users before this release ships (GitHub issue, Discussions)? See D6.
