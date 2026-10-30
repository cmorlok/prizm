# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Confirm server behaviour (0.5 d)

- [ ] 1.1 On Vaultwarden 1.37.4 and Bitwarden self-hosted, record in design.md, Context: the v2 response (`cipherResponse` present?), the delete response (`cipher` present?), the 400 body for a storage-limit and a premium rejection, and the status of a download URL used 2 minutes after sync.
- [ ] 1.2 Record the status of `GET /api/ciphers/{id}/attachment/{aid}` for a deleted attachment on both servers (Open Question 2).
- [ ] 1.3 Confirm that Bitwarden self-hosted with default storage returns `fileUploadType: 0`.

## 2. Rollback (1–1.5 d)

- [ ] 2.1 Failing tests with a mock API: upload fails → DELETE sent, original error rethrown; cancellation → DELETE sent; DELETE fails → `uploadFailedRecordLeft`; metadata POST fails → no DELETE.
- [ ] 2.2 Implement D1 in `AttachmentRepositoryImpl.upload` (detached rollback task).
- [ ] 2.3 Remove `Attachment.isUploadIncomplete`, the mapper rule and the Retry UI and its view-model code. Update affected tests.
- [ ] 2.4 Failing test: blob 404 after a fresh URL → `fileMissingOnServer`. Row message with Delete; VoiceOver label; DesignSystem tokens.

## 3. Fresh download URL (0.5 d)

- [ ] 3.1 Failing tests: fresh URL fetched first even when the sync URL exists; fresh-URL 404 → sync URL used; no 403 retry loop.
- [ ] 3.2 Implement D2; request the blob with `.reloadIgnoringLocalCacheData`.

## 4. Error messages (0.5 d)

- [ ] 4.1 Failing tests: 400 with `{"message": "…"}` → `serverRejected(message:)` on metadata POST and on file upload; 400 without JSON → generic error with status in the log.
- [ ] 4.2 Implement D3; remove `premiumRequired` and the 402 branch; update the add sheet text.

## 5. Metadata refresh and multipart (0.75–1 d)

- [ ] 5.1 Failing tests: after upload and after delete, the cached item's `revisionDate` and attachment list come from the response, and `LegacyAttachmentListPatch` is not called.
- [ ] 5.2 Failing tests for the legacy path: a delete with an empty 200 body (Vaultwarden 1.32.0, Bitwarden server v2024.6.0) and a v2 response without `cipherResponse` succeed; the attachment list is patched by `LegacyAttachmentListPatch`.
- [ ] 5.3 Implement D5 (decode `cipherResponse` / `cipher`, map with the effective key). Move today's local patch into `LegacyAttachmentListPatch` with the `// LEGACY(...)` marker from design D5.
- [ ] 5.4 Failing test: the multipart `filename` is the encrypted file name. Implement D6.

## 6. Temp files (1 d)

- [ ] 6.1 Failing tests for `AttachmentTempFileManager`: files go to `PrizmAttachments/`; `sweepAll()` empties it; launch sweep removes files left from a previous run; unrelated temp files are untouched.
- [ ] 6.2 Call `sweepAll()` on `vaultDidLock`, sign-out, `willTerminate` and launch. §VII comment: goal, best-effort zeroing on APFS/SSD, what is not done.
- [ ] 6.3 XCUITest or integration test: open an attachment, lock, folder empty.

## 7. Release (0.5 d)

- [ ] 7.1 Interop check on the rig: upload with forced failure → no orphan in the browser extension; download 5 minutes after sync on Vaultwarden. If an older Vaultwarden (1.32.0 or 1.33.0) is available, delete an attachment there and confirm the list updates.
- [ ] 7.2 Security review: temp-file folder permissions and sweeps; no file names or tokens in logs.
- [ ] 7.3 README "Known Limitations": Azure note (D4); remove the premium sentence or reword it to "the server's message is shown".
- [ ] 7.4 SECURITY.md: temp-file lifecycle row updated (lock, quit, launch sweep).
- [ ] 7.5 CHANGELOG "Fixed": downloads no longer fail a minute after sync on Vaultwarden; failed uploads no longer leave broken attachments; server error messages are shown; opened attachment files are deleted on lock and quit.
- [ ] 7.6 `openspec validate fix-attachment-transfer-flow --type change --strict`.
