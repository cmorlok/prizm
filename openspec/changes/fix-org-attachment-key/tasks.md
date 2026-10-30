# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Confirm and reproduce (0.5 d)

- [ ] 1.1 Re-read SDK `cipher.rs` (`decrypt_cipher_key`, `key_identifier`, `make_attachment_material`) at the commit used for implementation and update the line references in design.md, Context, if they moved.
- [ ] 1.2 Failing test (regression guard): sync an org item without its own key, then upload an attachment through `UploadAttachmentUseCaseImpl` with a mock API. Assert that the attachment key in the v2 request decrypts with the org key. Fails today (vault key).
- [ ] 1.3 Failing test: create an org item, upload an attachment before any sync. Same assertion.

## 2. Key source and resolution (1 d)

- [ ] 2.1 Failing tests for `VaultKeyServiceImpl`: `.itemKey`, `.organization` (org key present / missing → `organizationKeyUnavailable`), `.personal`, no entry → `cipherKeyUnavailable`, locked → `vaultLocked`.
- [ ] 2.2 Implement `CipherKeySource`, change `VaultKeyCache` storage, pass `OrgKeyCache` to `VaultKeyServiceImpl` (`AppContainer`). `clear()` still zeroes item keys; extend its test.
- [ ] 2.3 Add `VaultError.cipherKeyUnavailable` with its user message; reuse `.organizationKeyUnavailable` (design D5). Rewrite the `VaultKeyServiceImpl` doc comment with the §VII security notes (goal, rule, source, no fallback).

## 3. Record sources (0.5 d)

- [ ] 3.1 Failing test: after sync, every mapped item has an entry (personal keyless, personal keyed, org keyless, org keyed).
- [ ] 3.2 Failing test: after `create`, the new ID has `.personal` or `.organization(orgId)`.
- [ ] 3.3 Implement D2 in `decryptList`, `SyncRepositoryImpl` and `VaultRepositoryImpl.create`. Tasks 1.2 and 1.3 now pass.

## 4. Wrongly keyed attachments (1–1.5 d)

- [ ] 4.1 Failing mapper tests: keyless org item, attachment file name under the vault key → kept with `wrappedWithPersonalKey = true`; under neither key → dropped; keyed org item and personal item → no second attempt.
- [ ] 4.2 Failing test: download of a flagged attachment unwraps its key with the vault key and decrypts.
- [ ] 4.3 Implement D3 (`CipherMapper`, `AttachmentMapper`, `Attachment` flag, `VaultKeyService.personalKey()`, `DownloadAttachmentUseCaseImpl`).
- [ ] 4.4 Row warning "Only you can open this file" with VoiceOver label and hint; the "Convert" action comes from `fix-attachment-file-format`. DesignSystem tokens only.
- [ ] 4.5 Log one `.info` line per sync with the count of flagged attachments (no names).

## 5. Release (0.5 d)

- [ ] 5.1 Interop check on the rig: Prizm uploads to a keyless org item → a second member opens it in an official client (browser extension, web vault or `bw` CLI, which share the TypeScript client code). A Prizm 1.5.0 upload to an org item appears in Prizm with the warning, opens, and after conversion opens for the second member.
- [ ] 5.2 Mandatory security review: key selection, no fallback paths left (grep for `currentKeys()` in attachment code), no key bytes in logs, zeroing on lock.
- [ ] 5.3 CHANGELOG "Fixed": attachments on organization items are encrypted with the organization key, so other members can open them; attachments that earlier versions saved with the wrong key are shown again and can be converted.
- [ ] 5.4 `openspec validate fix-org-attachment-key --type change --strict`.
