# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

Runs: red `20261030T090257Z` (compile: `AttachmentTransferFlowTests` against the old API), green
`20261030T091319Z` (1115 unit tests). Review fixes: red `20261030T132054Z` (compile:
`TempFileManaging` without the sweep generation), green `20261030T132134Z` (1124). Squashed code
commit ae2d94cf: `20261030T133908Z`, 1124 passed, 0 failed. The temp-folder, sweep and record
applier tests were written after the code (no separate red run); the tasks below say so.

## 1. Confirm server behaviour (0.5 d)

- [x] 1.1 On Vaultwarden 1.37.4 and Bitwarden self-hosted, record in design.md, Context: the v2 response (`cipherResponse` present?), the delete response (`cipher` present?), the 400 body for a storage-limit and a premium rejection, and the status of a download URL used 2 minutes after sync. Done for Vaultwarden 1.37.4 (rig `026.1.1`, `026.1.1.url`; recorded in Context). Not measured: the 2-minute point, the 400 bodies (not reproducible on Vaultwarden), Bitwarden self-hosted (no rig; documented gap, accepted by Christian 2026-10-30).
- [x] 1.2 Record the status of `GET /api/ciphers/{id}/attachment/{aid}` for a deleted attachment on both servers (Open Question 2). Vaultwarden 1.37.4: 400 'Attachment doesn't exist' (rig `026.1.2`). Bitwarden self-hosted not available (documented gap); Open Question 2 stays open.
- [x] 1.3 Confirm that Bitwarden self-hosted with default storage returns `fileUploadType: 0`. Not checked: no Bitwarden self-hosted rig (documented gap, accepted by Christian 2026-10-30). Source reading in D4 (Direct unless Azure storage is configured).

## 2. Rollback (1–1.5 d)

- [x] 2.1 Failing tests with a mock API: upload fails → DELETE sent, original error rethrown; cancellation → DELETE sent; DELETE fails → `uploadFailedRecordLeft`; metadata POST fails → no DELETE. Done: `AttachmentTransferFlowTests` (`testUploadFails_deletesTheNewRecord_andRethrows`, `testUploadCancelled_stillDeletesTheNewRecord` cancels the calling task, `testRollbackFails_reportsTheRecordLeftBehind`, `testRollbackFindsTheRecordGone_reportsOnlyTheUploadError`, `testMetadataFails_sendsNoDelete`); red `20261030T090257Z`.
- [x] 2.2 Implement D1 in `AttachmentRepositoryImpl.upload` (detached rollback task). Done: `rollBack(cipherId:attachmentId:after:)` with `Task.detached`; a 404 or Vaultwarden's 400 "Attachment doesn't exist" counts as already gone.
- [x] 2.3 Remove `Attachment.isUploadIncomplete`, the mapper rule and the Retry UI and its view-model code. Update affected tests. Done: no `isUploadIncomplete`, `retryUpload`, `retryButton` or `premiumRequired` left in the code; `AttachmentMapperTests`, `AttachmentEntityTests`, `AttachmentRowViewModelTests` updated.
- [x] 2.4 Failing test: blob 404 after a fresh URL → `fileMissingOnServer`. Row message with Delete; VoiceOver label; DesignSystem tokens. Code and unit tests done (`testDownload_blob404_isFileMissingOnServer_withoutRetry`, `test_open_fileMissing_setsTheMissingState_notAnError`; row `missingFileActions` with a labelled Delete button). Hand check 2026-10-30 (Christian, VoiceOver, planted `missing-file-check.txt` on "Fixture Twin"): the message showed but was not spoken, because focus stays in the item list; fixed (the missing-file state and row errors are announced at high priority), confirmed by Christian after the fix.

## 3. Fresh download URL (0.5 d)

- [x] 3.1 Failing tests: fresh URL fetched first even when the sync URL exists; fresh-URL 404 → sync URL used; no 403 retry loop. Done: `testDownload_fetchesAFreshURLFirst_evenWithASyncURL`, `testDownload_freshURL404_usesTheSyncURL`, `testDownload_blob403_failsWithoutALoop`, `testDownload_freshURL400_isDownloadFailed`.
- [x] 3.2 Implement D2; request the blob with `.reloadIgnoringLocalCacheData`. Done: `AttachmentRepositoryImpl.download`; `PrizmAPIClient.downloadBlob` builds a `URLRequest` with that cache policy.

## 4. Error messages (0.5 d)

- [x] 4.1 Failing tests: 400 with `{"message": "…"}` → `serverRejected(message:)` on metadata POST and on file upload; 400 without JSON → generic error with status in the log. Done: `testMetadata400WithMessage_isServerRejected`, `testFileUpload400WithMessage_isServerRejected_afterTheRollback`, `test400WithoutJSON_staysAnHTTPError`.
- [x] 4.2 Implement D3; remove `premiumRequired` and the 402 branch; update the add sheet text. Done: `AttachmentRepositoryImpl.serverRejection`; the add sheet shows `AttachmentError.errorDescription` ("The server rejected the upload: <message>"), `AttachmentAddViewModelTests.test_confirm_serverRejected_showsTheServerMessage`.

## 5. Metadata refresh and multipart (0.75–1 d)

- [x] 5.1 Failing tests: after upload and after delete, the cached item's `revisionDate` and attachment list come from the response, and `LegacyAttachmentListPatch` is not called. Done: `testUpload_takesTheItemFromTheV2Answer`, `testDelete_takesTheItemFromTheAnswer`; `RevisionRefreshTests.testAttachmentAnswer_isTakenWithoutAGet`, `…ForAnotherItem_isNotApplied`, `…WithoutRevision_changesNothing`, `…AfterLock_isNotApplied`. The `RevisionRefreshTests` applier tests were written after the code.
- [x] 5.2 Failing tests for the legacy path: a delete with an empty 200 body (Vaultwarden 1.32.0, Bitwarden server v2024.6.0) and a v2 response without `cipherResponse` succeed; the attachment list is patched by `LegacyAttachmentListPatch`. Done: `testDelete_withEmptyAnswer_patchesTheListLocally`, `testUpload_withoutItemInTheAnswer_patchesTheListLocally`, `testUpload_answerItemThatCannotBeApplied_fallsBackToTheLocalPatch`; wire test `AttachmentTransferWireTests.testDeleteAnswer_empty200_isNoItem`.
- [x] 5.3 Implement D5 (decode `cipherResponse` / `cipher`, map with the effective key). Move today's local patch into `LegacyAttachmentListPatch` with the `// LEGACY(...)` marker from design D5. Done: `AttachmentMetadataResponse.cipherResponse`, `AttachmentDeleteResponse`, `VaultRepositoryImpl.applyAttachmentChange` (`AttachmentRecordApplying`), `Data/Repositories/LegacyAttachmentListPatch.swift` with the marker; wire tests `testV2Answer_carriesTheItem`, `testDeleteAnswer_carriesTheItem`.
- [x] 5.4 Failing test: the multipart `filename` is the encrypted file name. Implement D6. Done: `AttachmentTransferFlowTests.testDirectUpload_namesThePartWithTheEncryptedFileName` and the wire test `AttachmentTransferWireTests.testDirectUpload_namesThePartWithTheEncryptedFileName` (body read from the request).

## 6. Temp files (1 d)

- [x] 6.1 Failing tests for `AttachmentTempFileManager`: files go to `PrizmAttachments/`; `sweepAll()` empties it; launch sweep removes files left from a previous run; unrelated temp files are untouched. Done, tests written after the code: `AttachmentTempFileManagerTests` (`test_write_putsTheFileIntoTheOwnerOnlyFolder` with mode 0700, `test_sweepAll_emptiesTheFolder_evenBeforeTheDeadline` including an unregistered file from an earlier run, `test_sweepAll_leavesFilesOutsideTheFolder`, `test_write_afterASweep_isRefused_andLeavesNoFile`). The launch call itself (`AppContainer.init`) has no test; declined in review, `sweepAll()` is what it runs.
- [x] 6.2 Call `sweepAll()` on `vaultDidLock`, sign-out, `willTerminate` and launch. §VII comment: goal, best-effort zeroing on APFS/SSD, what is not done. Done: `PrizmApp.swift` (lock `:621`, sign-out `:585`, quit `:412`), `AppContainer.swift:195` (launch); §VII comment on `AttachmentTempFileManager`. Tests written after the code: `RootViewModelLockTests.testLockVault_sweepsOpenedAttachmentFiles`, `testSignOut_…`, `testQuit_…`.
- [x] 6.3 XCUITest or integration test: open an attachment, lock, folder empty. Done as an integration unit test: `RootViewModelLockTests.testOpenAttachmentThenLock_leavesTheFolderEmpty` (real `AttachmentTempFileManager` and `AttachmentRowViewModel`, lock through `RootViewModel`).

## 7. Release (0.5 d)

- [x] 7.1 Interop check on the rig: upload with forced failure → no orphan in the browser extension; download 5 minutes after sync on Vaultwarden. If an older Vaultwarden (1.32.0 or 1.33.0) is available, delete an attachment there and confirm the list updates. Done: rig run `20261030T113852Z` on Vaultwarden 1.37.4: `prizm 026.7.1.rollback` and `026.7.1.orphan` (forced failure; the official `bw` CLI 2026.9.1, which uses the same SDK as the browser extension, lists no orphan), `prizm 026.7.1.late` (download 5 minutes after sync, content matches). No older Vaultwarden container was available. The run predates the review fixes (green `20261030T132134Z`).
- [x] 7.2 Security review: temp-file folder permissions and sweeps; no file names or tokens in logs. Done: independent review 2026-10-30; the one open point (a download finishing after a lock) is fixed; security note in design.md "Review".
- [x] 7.3 README "Known Limitations": Azure note (D4); remove the premium sentence or reword it to "the server's message is shown". Done: both bullets in README "Known Limitations".
- [x] 7.4 SECURITY.md: temp-file lifecycle row updated (lock, quit, launch sweep). Done: "Temp file lifecycle (Open action)" item 3, best-effort zeroing; "Upload-incomplete state" replaced by "Failed uploads".
- [x] 7.5 CHANGELOG "Fixed": downloads no longer fail a minute after sync on Vaultwarden; failed uploads no longer leave broken attachments; server error messages are shown; opened attachment files are deleted on lock and quit. Done: entries under "Unreleased" ("Fix: opening or saving an attachment failed on Vaultwarden …", "Fix: a failed or cancelled attachment upload no longer leaves a broken attachment entry …", "Fix: when the server refuses an upload …", "Fix: attachment files opened from Prizm are now deleted …", "Changed: the "Upload incomplete" state and its Retry button are gone …").
- [x] 7.6 `openspec validate fix-attachment-transfer-flow --type change --strict`. Done 2026-10-30: valid; `/opsx:verify`: no critical issues (its warnings are resolved by the archive-pass fix and the hand check, see design.md "Review").
- [x] 7.7 Archive the change (at the end of the batch, in PR order).
