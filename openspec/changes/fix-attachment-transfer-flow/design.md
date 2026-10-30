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

## Open Questions

1. Should Prizm send `lastKnownRevisionDate` on `attachment/v2`, as the SDK does
   (`create.rs:86-98`)? Vaultwarden 1.37.4 ignores it (`AttachmentRequestData`,
   `ciphers.rs:1148-1155`). `fix-cipher-edit-data-loss` sends it on full item updates only (its
   design D6), so this stays open here.
2. Does the Bitwarden server's `GET …/attachment/{aid}` return 404 or 400 for a missing
   attachment on an existing item (`GetAttachmentDownloadDataAsync`)? Task 1.2.
