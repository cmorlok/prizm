# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-org-attachment-key` is merged, or lands in the same release (stacked branch).

## 1. Vectors and server facts (0.5 d)

- [ ] 1.1 Add the SDK vector (`pure_crypto.rs:396-411`, key + 65-byte buffer → `"test"`) as a test fixture. Record its source path and commit in the test file.
- [ ] 1.2 On Vaultwarden 1.37.4 and on Bitwarden self-hosted: upload one file from the browser extension and one from Prizm 1.5.0. Record in design.md, Context, the `size` each server returns in `/api/sync` and confirm `size mod 16` (1 for official, 0 for Prizm 1.5.0).

## 2. Read and write (1 d)

- [ ] 2.1 Failing test: decrypting the SDK vector returns `"test"` (fails today with `macMismatch`).
- [ ] 2.2 Failing test: `encryptData` output has byte 0 = `0x02`, length `49 + 16k`, MAC at offset 17 over `IV ‖ ciphertext`.
- [ ] 2.3 Failing tests for D2: old Prizm blob opens; old Prizm blob whose IV starts with `0x02` opens; type-0 blob throws `unsupportedEncryptionType`; lengths 0, 49, 50, 63 and `16k + 5` throw `malformedBlob`; one flipped byte in each layout throws `macMismatch`.
- [ ] 2.4 Implement D1 and D2 in `AttachmentCrypto.swift`. Replace the "matches the Bitwarden Attachments binary format" comment with the real source (SDK `symmetric.rs`, TS `enc-array-buffer.ts`) and the §VII security notes: goal, algorithm, why type 0 is refused, why the old layout is still read.

## 3. Conversion (1.5–2 d)

- [ ] 3.1 Failing mapper test: `Attachment.storedInLegacyPrizmFormat` is true for `size = "1072"`, false for `"1073"`.
- [ ] 3.2 Failing repository tests for D4 with a mock API: happy path (POST v2, upload, DELETE old, cache shows one attachment with the new ID); upload fails (DELETE new, old kept); delete of old fails (both kept, typed partial-success error); blob is already official (no write calls).
- [ ] 3.3 Failing test: converting an org item's attachment wraps the new attachment key with the org key, not the vault key; also for an attachment flagged `wrappedWithPersonalKey` (downloaded with the vault key).
- [ ] 3.4 Implement `AttachmentRepository.convertLegacyFormat` and `ConvertAttachmentUseCase` (Domain protocol, Data impl). Zero plaintext and keys on every path.

## 4. User flow (1–1.5 d)

- [ ] 4.1 Failing view-model tests: the notice appears once per unlock when editable legacy attachments exist; "Convert all" processes files sequentially, reports `n of N`, stops on cancel, lists failures.
- [ ] 4.2 Row badge, "Convert" action, notice and progress UI. DesignSystem tokens only. (The read-only hint moves to `honour-org-item-permissions`, design D5.)
- [ ] 4.3 VoiceOver: labels and hints for the badge, the action, the notice and progress (§VIII). Add accessibility identifiers.
- [ ] 4.4 XCUITest: open an item with a legacy attachment (fixture), convert it, the badge disappears.

## 5. Interop and security (0.5 d)

- [ ] 5.1 On the rig: upload from Prizm → open in the browser extension and web vault; upload from the extension → open in Prizm; convert a Prizm 1.5.0 upload → open in the extension. Personal item and org item.
- [ ] 5.2 Mandatory security review: blob parsing bounds, MAC-before-decrypt on both layouts, type 0 refused, new key from `SecRandomCopyBytes`, zeroing, no file names or key bytes in logs.

## 6. Docs and release (0.5 d)

- [ ] 6.1 CHANGELOG "Fixed" entry as in design D6.
- [ ] 6.2 Release-notes draft (affected versions, "Convert all"). Hand it to the maintainer; publishing it upstream needs Christian's go-ahead.
- [ ] 6.3 README: correct the attachment feature line if needed and add the conversion note to "Known Limitations".
- [ ] 6.4 Mark `openspec/specs/attachment-crypto/spec.md` (blob layout requirement) as superseded by `attachment-file-format` at archive time.
- [ ] 6.5 `openspec validate fix-attachment-file-format --type change --strict`.
