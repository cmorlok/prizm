# Proposal

## Why

**Criticality:** P0 (Critical)
**Findings:** C-01 (`02-crypto.md`), A-01 (`05-attachments-totp-icons.md`)

Prizm stores attachment files in its own byte layout, not in the layout every official Bitwarden
client uses:

- Prizm writes `IV(16) ‖ ciphertext ‖ HMAC(32)` (`AttachmentCrypto.swift:109`).
- Official clients write an EncArrayBuffer: `0x02 ‖ IV(16) ‖ MAC(32) ‖ ciphertext`.

The algorithm (AES-256-CBC, HMAC-SHA256 over `IV ‖ ciphertext`, MAC checked first) is the same.
Only the order of the bytes and the leading type byte differ. The result:

- **Official clients can't open any file uploaded with Prizm.** They read the first IV byte as the
  encryption type and fail. This affects every attachment Prizm has uploaded since v1.1.0
  (2026-04-09, commit `6f5bfff`), on every server. Users who rely on another Bitwarden app, or who
  share an organization with others, have files that only Prizm can open.
- **Prizm can't open any file uploaded by an official client.** It fails with `macMismatch` and
  shows "Could not open file".

Nobody can recover these files through an official client. If a user stops using Prizm, the files
are lost for them in practice.

## Origin of the current behaviour

**Wrong premise.** The archived spec states the layout as fact:
`openspec/changes/archive/2026-04-09-vault-document-storage/specs/attachment-crypto/spec.md:17`:
"*with layout: 16-byte IV ‖ ciphertext ‖ 32-byte HMAC. This is the same algorithm as EncString type
2 but a different wire format*". The code comment `AttachmentCrypto.swift:38-39` claims it
"matches the Bitwarden Attachments binary format described in the Bitwarden Security Whitepaper
§4". The tests only round-trip Prizm to Prizm (`PrizmTests/Data/AttachmentCryptoTests.swift`).
No official test vector was used.

## What Changes

- **Write the official layout.** New uploads are `0x02 ‖ IV ‖ MAC ‖ ciphertext`.
- **Read both layouts.** Prizm reads the official type-2 layout and, for files it uploaded itself
  before this fix, the old Prizm layout. The layout is chosen from the blob length (see design D2),
  and the MAC check then confirms it. No trial decryption.
- **Reject type 0 (no MAC)**, as official clients do.
- **Convert old files.** After a sync, Prizm lists attachments that are probably in the old layout
  (from the encrypted size reported by the server, design D3). The user can convert them, one at a
  time or all at once. Conversion downloads the file, re-encrypts it in the official layout with a
  new attachment key, uploads it as a new attachment, and deletes the old one. This is the same
  approach as the SDK's `upgrade_attachment`.
- **Tell users.** CHANGELOG, README "Known Limitations" and the release notes say which files are
  affected and how to convert them.
- Fix the wrong spec text and the comments that claim whitepaper conformance.

## Capabilities

### New Capabilities
- `attachment-file-format`: the binary layout Prizm writes and reads for attachment files, and the
  conversion of files written in Prizm's old layout.

### Modified Capabilities
- `attachment-crypto`: the requirement "File data encrypted with attachment key" stated Prizm's
  own blob layout as the Bitwarden format. It now refers to `attachment-file-format` for the
  layout.

## Non-Goals

- Legacy attachments without their own key (`key: null`, finding A-03):
  `fix-sync-decoding-resilience`.
- Streaming encryption for large files. Prizm keeps loading the whole file (limit 500 MB).
- COSE / type-7 attachment blobs (v2 accounts). Prizm doesn't support those accounts.
- Converting files on items the user can't edit. Prizm still reads them. Someone with edit access
  has to convert them.
- Automatic conversion without asking. Conversion writes to the server and changes attachment IDs,
  so the user decides.
- Hiding "Convert" on items the user can only view. Prizm does not decode per-item permissions yet;
  `honour-org-item-permissions` does, and takes over that part (design D5). Until then the server's
  refusal is shown.

## Dependencies

- **Hard:** `fix-org-attachment-key`. Without it, uploads and conversions on organization items
  without their own key are still wrapped with the personal vault key. Conversion would then
  create a new file no other member can read. It must land first or in the same release.
- **Soft:** `fix-attachment-transfer-flow`. Conversion uses the upload path. That change adds the
  rollback (delete the new attachment if its upload fails) and the fresh download URL. Conversion
  needs both. If this change lands first, it implements the rollback for conversion itself.
- Recommended: release all three attachment changes together.
- **Branch:** stacked on `fix-org-attachment-key` (`fix/027`), which is stacked on
  `fix-attachment-transfer-flow` (`fix/026`), so conversion uses both.

## Impact

- **Data:**
  - `Data/Crypto/AttachmentCrypto.swift`: `encryptData` writes the new layout; `decryptData`
    reads both layouts and rejects others.
  - New `AttachmentRepository.convertLegacyFormat(cipherId:attachment:)` (download, decrypt,
    re-encrypt, upload, delete old).
  - `AttachmentMapper`: sets the new Domain flag from the encrypted size.
- **Domain:** `Attachment.storedInLegacyPrizmFormat: Bool`; new `ConvertAttachmentUseCase`;
  `AttachmentError.alreadyStandardFormat` and `.convertedOldCopyLeft`.
- **Presentation:** attachment row badge and "Convert" action; a one-time notice after sync with
  "Convert all"; progress and errors. VoiceOver labels for all of these (§VIII). DesignSystem
  tokens only.
- **No new dependencies.**
- **Security review required** (§III): binary format parsing, key generation for converted files,
  zeroing of plaintext during conversion.

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Test vectors from the SDK, confirm sizes reported by both servers | 0.5 d |
| 2 | Write the new layout, read both layouts, reject type 0 | 1 d |
| 3 | Conversion in Data (download, re-encrypt, upload, delete, rollback, cache patch) | 1.5–2 d |
| 4 | Domain flag and use case, row badge, "Convert all" notice, VoiceOver | 1–1.5 d |
| 5 | Interop check with official clients, security review | 0.5 d |
| 6 | CHANGELOG, README, release notes, spec and comment corrections | 0.5 d |
| **Total** | | **5–6 d** |
