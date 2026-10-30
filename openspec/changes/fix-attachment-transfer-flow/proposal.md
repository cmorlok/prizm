# Proposal

## Why

**Criticality:** P1 (High)
**Findings:** A-04, A-05, A-06, A-07, A-08, A-10, A-12 (`05-attachments-totp-icons.md`)

Several parts of the attachment upload and download flow rely on server behaviour that neither
server has. Users notice it:

- **Downloads fail about 90 seconds after a sync on Vaultwarden (A-05).** Prizm uses the download
  URL from the sync. Vaultwarden signs it for 1 minute plus 30 seconds of leeway, and an expired
  link returns 404. Prizm only refreshes the URL on 403, so the download fails.
- **A failed upload leaves a broken attachment on the server (A-04).** Prizm registers the
  attachment, then uploads the file. If the upload fails or the user cancels, the record stays.
  Every client then shows an attachment that can't be opened, and it counts against storage.
  Prizm's "upload incomplete" warning never appears, because it waits for an empty URL that no
  server sends. On Vaultwarden the storage-limit check runs during the file upload, so "storage
  full" always leaves such a record.
- **Wrong error messages (A-06).** Prizm expects HTTP 402 for "premium required". Both servers send
  400 with a message ("You must have premium status to use attachments.", "Attachment storage limit
  reached! …"). Users see "Upload failed: …" with a generic code.
- **Decrypted files stay on disk (A-12).** "Open" writes the plaintext to the temp folder and
  deletes it after 30 seconds or on the next app activation. Quit, crash or lock within that time
  leaves it there.
- Smaller gaps: after an attachment change the item is fetched again instead of taken from the
  upload or delete answer, and the new attachment keeps its locally built record until the next
  sync (A-08; the revision itself is refreshed since `fix-cipher-edit-data-loss`), the multipart file
  name differs from official clients (A-10), and Azure block upload is missing (A-07).

## Origin of the current behaviour

- **A-04, A-05, A-06: wrong premise.** `openspec/changes/archive/2026-04-09-vault-document-storage/design.md`:
  - `:116`: "On next sync, detect attachments with metadata but no resolvable download URL; show
    'upload incomplete' state and offer retry/delete".
  - `:155`: "Use `Attachment.url` from sync payload directly when non-nil; signed URLs expire — on
    403, discard the stale URL and re-fetch".
  - `:108`, `:119`: "Catch HTTP 402".
- **A-07: known gap.** `design.md:120` planned "re-request a new signed URL and retry once on
  403"; it was never implemented.
- **A-12: deliberate** temp-file design (`design.md:60-66`); cleanup on lock, quit and launch was
  not considered.
- **A-08, A-10: accidental.**

## What Changes

- **Roll back failed uploads.** After the metadata POST, any failure or cancellation sends
  `DELETE /api/ciphers/{id}/attachment/{attachmentId}`, as official clients do.
- **Remove the "upload incomplete" state** and its Retry button. Replace it with a "file missing on
  the server" message when a download finds no file, with a Delete action.
- **Always fetch a fresh download URL** before downloading. Use the sync URL only if that call
  returns 404, as the official clients do.
- **Show the server's message** for 400 responses. Remove the 402 mapping.
- **Refresh the item's revision date** (and attachment list) from the server response after an
  attachment upload or delete. Servers whose delete response has no item (Vaultwarden < 1.34.0,
  Bitwarden server < v2026.2.1) keep today's local patch, in a legacy adapter (design D5).
- **Send the encrypted file name** as the multipart part's `filename`, as official clients do.
- **Clean up temp files** in a dedicated folder on lock, sign-out, quit and launch.
- **Azure:** document that uploads to Azure-backed servers (Bitwarden cloud) are single-PUT only.
  No block upload (design D4).

## Capabilities

### New Capabilities
- `attachment-transfer`: upload rollback, download URL handling, error messages, metadata refresh
  and temp-file lifecycle for attachments.

### Modified Capabilities
_None in this delta._ Related existing specs, to be corrected when this change is archived:
`openspec/specs/attachment-api/spec.md` (sync URL used directly, line 34 and 49; incomplete upload,
line 28), `openspec/specs/attachment-view-flow/spec.md` and `openspec/specs/attachment-add-flow/spec.md`
(Retry and 402 wording).

## Non-Goals

- Azure block upload and URL renewal (design D4). Prizm v1 targets self-hosted servers only
  (Constitution, "Bitwarden API Integration Requirements").
- A premium check before upload. The server's message is shown instead (design D3).
- Streaming download or upload.
- Changing the 30-second delay before an opened file is deleted.

## Dependencies

- `fix-cipher-edit-data-loss` (landed): it refreshes the stored record with a fetch after an
  attachment upload or delete. D5 here takes the record from the upload and delete responses
  instead, and keeps the fetch only for servers whose response has no item.
- **Soft:** `fix-attachment-file-format` uses the rollback (D1) for conversion. Release together.
- No hard dependencies.

## Impact

- **Data:** `AttachmentRepositoryImpl` (rollback, fresh URL, error mapping, response refresh);
  `PrizmAPIClient` (multipart file name, decoding `cipherResponse` and the delete response,
  `message` from 400 bodies); `AttachmentMapper` (drop `isUploadIncomplete`).
- **Domain:** `Attachment.isUploadIncomplete` removed; `AttachmentError.serverRejected(message:)`
  and `.fileMissingOnServer` added; `.premiumRequired` removed.
- **App:** `AttachmentTempFileManager` gets a dedicated folder and sweeps on lock, sign-out, quit
  and launch.
- **Presentation:** remove Retry UI; add the missing-file message with Delete; error texts.
  VoiceOver labels for the new states.
- **No new dependencies.**
- **Security review: yes** (plaintext temp files; the rest is protocol handling without new
  crypto).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm server responses (v2, delete, errors) on both servers | 0.5 d |
| 2 | Upload rollback, remove incomplete state, missing-file state | 1–1.5 d |
| 3 | Fresh download URL with 404 fallback | 0.5 d |
| 4 | Error messages from 400 bodies | 0.5 d |
| 5 | Revision date and attachment list from responses, legacy patch for older servers; multipart file name | 0.75–1 d |
| 6 | Temp-file folder and sweeps | 1 d |
| 7 | Interop check, security review, docs, CHANGELOG | 0.5 d |
| **Total** | | **4.75–5.5 d** |
