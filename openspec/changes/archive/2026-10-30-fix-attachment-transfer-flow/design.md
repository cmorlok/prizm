# Design

## Context

**Official upload flow.** Sources at HEAD 2026-10-23.
- TS `clients/libs/common/src/platform/services/file-upload/file-upload.service.ts:37-61`: any
  exception during the file upload calls `fileUploadMethods.rollback()` and rethrows.
- SDK `crates/bitwarden-vault/src/cipher/attachment_client/create.rs:160-205`: after the slot is
  created, a failure deletes it (`delete_attachment`, or `delete_attachment_admin` for admin
  requests), best effort. On success the client merges `cipher_response` from the v2 response into
  the local item (`create.rs:133-150`).
- Multipart: the part named `data` carries the encrypted file name EncString as `filename`
  (`bitwarden-file-upload.service.ts:12-27`).
- Azure: single PUT up to 256 MiB, block upload above, URL renewed when it is about to expire
  (`azure-file-upload.service.ts:11, 25-28, 121-131`). Server renew endpoint:
  `server/src/Api/Vault/Controllers/CiphersController.cs:1544-1545`.

**Official download flow.**
`clients/libs/vault/src/components/download-attachment/download-attachment.component.ts:71, 103-127`:
always call the SDK's `getAttachmentDownloadUrl` (`GET /api/ciphers/{id}/attachment/{aid}`) first;
fall back to `attachment.url` only when that call fails with `NotFound`. Then fetch with
`cache: "no-store"` and require HTTP 200.

**Delete.** SDK `attachment_client/delete.rs:24-49` merges the `cipher` from the delete response.
Vaultwarden returns `{"cipher": …}` (`src/api/core/ciphers.rs:2022-2023`); Bitwarden server returns
`DeleteAttachmentResponseModel` (`CiphersController.cs:1760`).

**Older servers.** Checked so that nothing that works today stops working:
- `GET /api/ciphers/{id}/attachment/{aid}`, `DELETE …/attachment/{aid}` and `POST …/attachment/v2`
  with `cipherResponse` exist on Vaultwarden 1.32.0 (`src/api/core/ciphers.rs:1028, 1064-1094,
  1378`, tag 1.32.0) and on Bitwarden server v2024.6.0 (`CiphersController.cs:992-1019, 1118,
  1148`). Prizm already calls the GET today, on 403 (`PrizmAPIClient.swift:989-997`).
- The delete response has no body on older servers. Vaultwarden returns `{"cipher": …}` from 1.34.0
  (`ciphers.rs:1863`, tag 1.34.0); 1.32.0 and 1.33.0 return an empty result (`ciphers.rs:1793`, tag
  1.32.0). The Bitwarden server returns `DeleteAttachmentResponseModel` from v2026.2.1; v2026.2.0
  and earlier return nothing (`CiphersController.cs:1150`, tag v2024.6.0). Today Prizm ignores the
  body (`PrizmAPIClient.swift:1000-1007`, `performEmpty`).

**Vaultwarden 1.37.4 specifics.**
- Download URL token: `exp = now + 1 min` (`src/auth.rs:436-444`), validation leeway 30 s
  (`src/auth.rs:129`). An invalid or expired token makes the file route return `None`, which is a
  404 (`src/api/web.rs:231-241`). A missing file on disk is also a 404.
- `POST …/attachment/v2` creates the record and returns `attachmentId`, `url`, `fileUploadType: 0`
  and `cipherResponse` (`src/api/core/ciphers.rs:1167-1209`). It never returns type 1 (Azure).
- Storage limits and "Attachments are disabled" are checked when the file is uploaded, after the
  record exists (`src/api/core/ciphers.rs:1258-1310`). A size mismatch deletes the record itself
  (`:1338-1340`); other errors don't.
- Errors are JSON with `message` and status 400 by default (`src/error.rs:131, 331`, `err!` macro
  `:341-351`). A missing attachment on `GET …/attachment/{aid}` is 400 "Attachment doesn't exist"
  (`ciphers.rs:1145`).
- **Rig result (tasks 1.1 and 1.2, 2026-10-30, run `20261030T113852Z`):** `POST …/attachment/v2`
  answers 200 with `cipherResponse` and `fileUploadType: 0`; the attachment DELETE answers 200 with
  `cipher` in the body; `GET …/attachment/{aid}` for a deleted attachment answers 400 "Attachment
  doesn't exist"; a download URL used 6.7 minutes after it was issued answers 404. The 2-minute
  point was not measured (the source gives 1 minute plus 30 s leeway). The storage-limit and
  premium 400 bodies could not be produced on Vaultwarden. Bitwarden self-hosted was not
  available, so its answers (Open Question 2, task 1.3) rest on the source reading above.

**Bitwarden server specifics.**
- Premium and storage errors are `BadRequestException` (400): "Not enough storage available."
  (`src/Core/Vault/Services/Implementations/CipherService.cs:1026`), "You must have premium status
  to use attachments." (`:1043`).
- `GET …/attachment/{aid}` on an unknown item throws `NotFoundException` (`CiphersController.cs:1681-1699`).
- Adding an attachment sets `cipher.RevisionDate = DateTime.UtcNow` (`CipherService.cs:229-231`).

**Prizm today.**
- `AttachmentRepositoryImpl.swift:98-125`: no rollback; only 402 mapped (`:101-103`).
- `AttachmentRepositoryImpl.swift:167-188`: sync URL first; refetch only on 403.
- `AttachmentRepositoryImpl.swift:142-145, 207-209`: patch the attachment list locally through
  `VaultRepository.updateAttachments`, which since `fix-cipher-edit-data-loss` also fetches the
  item (`GET /api/ciphers/{id}`) to refresh its stored record and cached revision
  (`VaultRepositoryImpl.swift`, `performUpdateAttachments`). The upload and delete answers are not
  read.
- `AttachmentMapper.swift:78`: `isUploadIncomplete: dto.url == nil`, never true with real servers.
- `PrizmAPIClient.swift:955`: `filename="attachment"`.
- `PrizmAPIClient.swift:972-986`: single Azure PUT.
- `APIError.serverMessage(statusCode:body:)` (`PrizmAPIClient.swift:379`, `server-error-texts`)
  already extracts the official message from an error body; the attachment flow doesn't use it.
- `AttachmentRowViewModel.swift:95-101, 228-234` writes `tmp/<UUID>.<ext>`;
  `App/AttachmentTempFileManager.swift` keeps the list in memory only, sweeps on activation.
- `PrizmApp.swift:590-620` (`lockVault`) clears key caches but not temp files; `signOut` (`:562`)
  and the `willTerminate` observer (`:401-405`, clipboard only) don't either.

## Goals / Non-Goals

**Goals**
- No attachment record without a file is left behind by a Prizm upload.
- Downloads work at any time after a sync.
- Users see the server's reason when the server rejects an upload.
- No decrypted attachment file outlives the vault session.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Roll back on any failure after the metadata POST

After `createAttachmentMetadata` succeeds, wrap the upload in `do/catch`. On any error, including
`CancellationError`, run `deleteAttachment(cipherId:attachmentId:)` in a detached task (so the
cancellation doesn't cancel the rollback), then rethrow the original error.

- Rollback succeeds: the user sees the upload error only.
- Rollback finds the record gone (404, or Vaultwarden's 400 "Attachment doesn't exist": it deletes
  the record itself on a size mismatch): log `.info`, rethrow the original error.
- Rollback fails otherwise: log `.error` and throw `AttachmentError.uploadFailedRecordLeft`. The
  user sees "Upload failed. A broken attachment entry may remain; delete it from the item."

**Remove `isUploadIncomplete`** and the Retry UI. They depend on a server signal that doesn't
exist. Broken records left by older Prizm versions or crashed clients are found on download (D2).

**Rejected alternative:** keep the Retry UI and detect incomplete uploads by `size == 0`. Neither
server reports that reliably for a record whose upload never started.

### D2. Always fetch a fresh download URL

1. `GET /api/ciphers/{id}/attachment/{aid}` → URL.
2. If that returns 404, use the sync URL (official fallback).
3. Fetch the blob with `cachePolicy = .reloadIgnoringLocalCacheData`.
4. Blob 404 after a fresh URL → `AttachmentError.fileMissingOnServer`. The row shows "The file is
   missing on the server" with a Delete action.
5. Other errors, of the URL request or the blob fetch → `downloadFailed` with the status code in the
   log. A record deleted elsewhere (Vaultwarden: 400 "Attachment doesn't exist" on the URL request)
   is one of them; the next sync removes the row.

No retry loop: the URL is already fresh.

### D3. Show the server's message for 400

`PrizmAPIClient` keeps 4xx bodies in `APIError.httpError(statusCode:body:)` as today;
`AttachmentRepositoryImpl` maps a 400 whose `APIError.serverMessage` is non-nil (both servers send
`message`) to `AttachmentError.serverRejected(message:)`. The add sheet shows "The server rejected the upload:
<message>". Remove `premiumRequired` and the 402 branch.

No premium check before upload. Vaultwarden reports premium for every user; Bitwarden self-hosted
returns a clear message. `totp-parity` adds the profile's premium flag; hiding "Add attachment"
for non-premium accounts can follow later if users ask.

### D4. Azure: document, don't implement

Vaultwarden never returns `fileUploadType: 1`. The Constitution limits v1 to self-hosted servers.
Bitwarden self-hosted returns Direct (0) unless an admin configures Azure storage (task 1.3
confirms). Prizm keeps the single PUT and, on failure, rolls back (D1). README "Known Limitations":
"Uploads to Azure-backed servers (Bitwarden cloud) larger than 256 MB may fail."

**Rejected alternative:** port block upload and renewal (about 1.5 d) for servers the project
doesn't target.

### D5. Refresh the item from the server response

- Upload: decode `cipherResponse` from the v2 response. After the file upload succeeds, take its
  `revisionDate` and its attachment list (mapped with the item's effective key) into the cache.
- Delete: decode `cipher` from the delete response and do the same.
- The item from the response becomes the item's stored record (the same store write and cache
  revision update `refreshRecord` does today with its fetch), so no extra `GET` is sent.
- An empty body or a response without the item is not an error. Then Prizm patches the attachment
  list locally and fetches the item, as it does today (`AttachmentRepositoryImpl.swift:142-145,
  207-209` with `VaultRepository.updateAttachments`), and logs `.info`. This path lives in its own type, `LegacyAttachmentListPatch` in `Data/Repositories/`,
  marked `// LEGACY(Vaultwarden < 1.34.0, Bitwarden server < v2026.2.1: delete returns no item):
  remove when those versions are no longer supported`. It is reached only when the response has
  no item, never as the default.
- On the legacy path the revision date comes from that fetch, as today; if the fetch fails, the
  next sync corrects it.

This keeps the cached `revisionDate` and the stored record (the source of `lastKnownRevisionDate`,
`fix-cipher-edit-data-loss` D6) correct with one request fewer. It also replaces the locally built
attachment (which has the plaintext size and no URL, `AttachmentRepositoryImpl.swift:131-140`) with
the server's record.

### D6. Multipart file name

`Content-Disposition: form-data; name="data"; filename="<encrypted file name EncString>"`, as the
official client. Both servers ignore it on the v2 path, so this is parity only.

### D7. Temp files live in one folder that is swept

- Write opened files to `FileManager.default.temporaryDirectory/PrizmAttachments/<UUID>.<ext>`
  (created with `0700`).
- Sweep the whole folder (zero, then delete each file) on: `vaultDidLock`, sign-out,
  `NSApplication.willTerminateNotification`, and app launch (covers crashes). Keep the existing
  30-second and activation sweeps.
- Overwriting with zeros is best effort on SSDs and APFS; deletion is the control that matters. The
  §VII comment says so.
- A download that finishes after a sweep is not written: every sweep bumps a generation, the row
  reads it before the download and the write refuses a stale one (`TempFileError.sweptSinceDownload`;
  the check and the write share the manager's lock). Nothing is opened and no error is shown.

**Rejected alternative:** no temp file at all (save dialog only, like desktop and web). "Open"
is a deliberate Prizm feature (`design.md:60`).

## Risks / Trade-offs

- **[Low] Extra request per download** (fresh URL). Same as official clients.
- **[Low] Rollback DELETE fails** (network gone). → The user is told; the record can be deleted
  manually.
- **[Low] Locking closes nothing in other apps.** A file already opened in Preview stays in
  Preview's memory; only the disk copy goes. Documented in SECURITY.md.

## Review

Independent review on 2026-10-30 (fresh reviewer, read only), no blockers, four should-fix findings
and six nits:
- Fixed: a rollback DELETE that finds the record already gone (404, or Vaultwarden's 400 "Attachment
  doesn't exist" after it deleted the record itself on a size mismatch) wrongly reported a broken
  entry. It now reports only the upload error (D1, `testRollbackFindsTheRecordGone_reportsOnlyTheUploadError`).
  D1 was corrected to the code: when the rollback fails for another reason, the user gets
  `uploadFailedRecordLeft` without the server's message, because the entry left behind is what the
  user has to act on.
- Fixed: a download that finished after a lock could still write and open the plaintext file.
  Every sweep now bumps a generation; the row reads it before the download, and the write refuses a
  stale one under the manager's lock (D7, `test_write_afterASweep_isRefused_andLeavesNoFile`,
  `test_open_lockDuringTheDownload_writesAndOpensNothing`).
- Fixed: the cancellation test did not cancel anything. It now cancels the calling task while the
  upload is suspended and checks that the DELETE ran uncancelled.
- Fixed: no test covered the wire code. `AttachmentTransferWireTests` checks the multipart
  `filename`, the item in the v2 and delete answers, and the empty 200 of older servers.
- Fixed (nit): an attachment answer without a readable revision changed the cached list before the
  revision check. The check now comes first, and nothing changes (`testAttachmentAnswerWithoutRevision_changesNothing`).
- Kept as designed (nit): Vaultwarden's 400 for an attachment deleted elsewhere stays
  `downloadFailed`, not the missing-file state; D2 step 5 says so, and the next sync removes the row.
- Declined (nit): no test for the launch sweep in `AppContainer.init`. It is one call to
  `sweepAll()`, which is tested, including a file left by an earlier run.
- Not addressed (nits, no change made): `AttachmentAddViewModel.cancel()` closes the sheet, so an
  `uploadFailedRecordLeft` after a cancel is set on a sheet nobody sees, and a cancel during the
  metadata POST can leave a record (official clients behave the same); `HStack(spacing: 6)` in
  `AttachmentRowView` is a raw literal from before this change; the debug log of a swept file shows
  its extension (the name is a UUID).

**Security review (task 7.2).** Opened files are written only to `<tmp>/PrizmAttachments`, inside
the sandbox container, created with mode `0700`; files are named `<UUID>.<ext>` and written with
`.withoutOverwriting`, and the plaintext buffer is zeroed on success and on a failed write.
`sweepAll()` lists the whole folder, so it also removes files a crashed run never registered; it
zeroes and deletes each file. It runs on lock (after the key teardown, and every automatic lock
goes through the same `lockVault`), on sign-out, on `willTerminate` and at launch; the 30-second
and activation sweeps stay. A download that ends after a sweep is neither written nor opened (sweep
generation, checked and written under one lock). Zeroing is best effort on APFS and SSDs, and a file
already open in another app stays in that app's memory; both are documented in SECURITY.md and the
§VII comment. Logs carry cipher and attachment ids, counts, status codes and `ErrorLog.describe`
output; no file name, download URL, token or key. The multipart `filename` is the encrypted file
name, never the plaintext. A failed upload deletes its record in a detached task, so a cancelled
upload cannot leave it behind unless that delete fails, which the user is told.

**Archive pass (2026-10-30).**
- Fixed: an error of the download-URL request other than an HTTP status (for example no network)
  passed through unmapped; it is now `downloadFailed`, as D2 step 5 says.
- Fixed (hand check, task 2.4): the missing-file message and row errors were shown but not spoken,
  because VoiceOver focus stays in the item list; both are now announced at high priority.
- Main specs: the scenarios this change replaces (402 premium text, sync URL first, one retry on
  403, "Upload incomplete") were removed from `attachment-api` and `attachment-add-flow` in the
  archive commit, so the MODIFIED deltas could be applied as written.

## Open Questions

1. Should Prizm send `lastKnownRevisionDate` on `attachment/v2`, as the SDK does
   (`create.rs:86-98`)? Vaultwarden 1.37.4 ignores it (`AttachmentRequestData`,
   `ciphers.rs:1148-1155`). `fix-cipher-edit-data-loss` sends it on full item updates only (its
   design D6), so this stays open here.
2. Does the Bitwarden server's `GET …/attachment/{aid}` return 404 or 400 for a missing
   attachment on an existing item (`GetAttachmentDownloadDataAsync`)? Task 1.2.
