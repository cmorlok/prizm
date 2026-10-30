## Purpose

Defines the network API contract for attachment operations — upload (v2 two-step flow), download (signed URL), delete, logging, and server rejections.

## Requirements

### Requirement: Upload attachment via two-step v2 signed-URL flow
The system SHALL upload an attachment using the v2 Bitwarden Attachments API. The v2 endpoint separates metadata creation from file upload:
1. `POST /api/ciphers/{cipherId}/attachment/v2` with JSON body `{ "fileName": "<encryptedFileName>", "key": "<encryptedAttachmentKey>", "fileSize": <plaintextSizeBytes> }` and `Authorization: Bearer <accessToken>`. The file name SHALL be encrypted as an EncString using the cipher key before sending.
2. The server response SHALL include `{ "attachmentId": "...", "url": "<signedUrl>", "fileUploadType": 0|1 }`, and on current servers the item as `cipherResponse` (see `attachment-transfer`).
3. For `fileUploadType` = `0` (Vaultwarden direct): `POST /api/ciphers/{cipherId}/attachment/{attachmentId}` (the `url` field resolves to this path) with the encrypted blob as the multipart form body field `data`, named with the encrypted file name.
4. For `fileUploadType` = `1` (Azure blob): `PUT <signedUrl>` with the encrypted blob as the raw request body and header `x-ms-blob-type: BlockBlob`.

#### Scenario: Step 1 POST is to the v2 endpoint and returns metadata with signed URL
- **WHEN** a valid POST is sent to `/api/ciphers/{id}/attachment/v2`
- **THEN** the response SHALL contain `attachmentId`, `url`, and `fileUploadType`

#### Scenario: Vaultwarden direct upload succeeds
- **WHEN** `fileUploadType` is `0`
- **THEN** the encrypted blob SHALL be uploaded via POST to the signed URL as multipart form data

#### Scenario: Azure blob upload sets correct header
- **WHEN** `fileUploadType` is `1`
- **THEN** the encrypted blob SHALL be uploaded via PUT with `x-ms-blob-type: BlockBlob`

#### Scenario: Upload interrupted after the metadata request
- **WHEN** the file upload fails or is cancelled after step 1 created the attachment record
- **THEN** the system SHALL delete that record again, as defined in `attachment-transfer` ("Failed uploads are rolled back")

---

### Requirement: Download attachment via signed URL
The system SHALL download an attachment on demand (not during sync). The download flow:
1. `GET /api/ciphers/{cipherId}/attachment/{attachmentId}` with `Authorization: Bearer <accessToken>` → response includes `{ "url": "<signedUrl>", ... }`. Only if this request answers 404 SHALL the `Attachment.url` from the sync payload be used instead.
2. `GET <signedUrl>` → raw encrypted blob, never from a cache
3. Decrypt blob using the attachment key (itself decrypted from the EncString metadata using the cipher key)

The system SHALL NOT cache the downloaded encrypted blob to disk. The decrypted plaintext SHALL be handled per the `attachment-view-flow` spec (temp file or save panel).

#### Scenario: Download always fetches a fresh URL first
- **WHEN** the user opens or saves an attachment, whether or not `Attachment.url` is set
- **THEN** the system SHALL first GET the attachment record to obtain a signed download URL, then GET the encrypted blob from that URL

#### Scenario: Sync URL used when the fresh URL request answers 404
- **WHEN** the request for a fresh download URL answers 404 and `Attachment.url` is non-nil
- **THEN** the system SHALL GET the encrypted blob from `Attachment.url`

#### Scenario: No retry loop on a refused download
- **WHEN** the download URL answers HTTP 403
- **THEN** the system SHALL show an error and SHALL NOT request another URL

---

### Requirement: Delete attachment
The system SHALL delete an attachment via `DELETE /api/ciphers/{cipherId}/attachment/{attachmentId}` with `Authorization: Bearer <accessToken>`. On a 200 response, the attachment SHALL be removed from the in-memory vault cache immediately, taking the item from the response when the server sends it (see `attachment-transfer`). No local cleanup is needed (attachment data is server-side only).

#### Scenario: Successful delete removes attachment from detail pane
- **WHEN** the server returns 200 for the DELETE request
- **THEN** the attachment SHALL disappear from the detail pane attachment list without requiring a full re-sync

#### Scenario: Delete failure shows inline error
- **WHEN** the server returns a non-200 status for DELETE
- **THEN** an inline error SHALL appear in the detail pane and the attachment SHALL remain visible

#### Scenario: Delete of an attachment whose file is missing
- **WHEN** the user deletes an attachment whose file is missing on the server
- **THEN** the system SHALL call `DELETE /api/ciphers/{cipherId}/attachment/{attachmentId}`; the row SHALL disappear from the detail pane on success

---

### Requirement: Structured logging for all attachment operations
All attachment network and crypto operations SHALL emit structured log entries via `os.Logger` with subsystem `com.prizm` and category `attachments`. Log levels SHALL follow §V of the Constitution: `.debug` for trace (e.g. "starting upload for cipherId X"), `.info` for normal flow completion (e.g. "attachment uploaded successfully"), `.error` for recoverable faults (e.g. network failure, a server rejection), `.fault` for unrecoverable states. Secrets (attachment keys, file contents, access tokens) MUST NOT appear in any log output.

#### Scenario: Upload start and success are logged at correct levels
- **WHEN** an upload begins
- **THEN** a `.debug` entry SHALL be emitted; on success a `.info` entry SHALL be emitted; neither SHALL contain key material or file contents

#### Scenario: Network failure during upload is logged at .error
- **WHEN** a network error occurs during upload
- **THEN** a `.error` entry SHALL be emitted with a description of the failure but no secret data

---

### Requirement: Premium gate — surface server error, don't pre-check
The system SHALL NOT call any profile or billing API to check premium status before showing the Add Attachment UI. When the server rejects an upload with HTTP 400 and a JSON `message` (for example "You must have premium status to use attachments." or a storage limit), the system SHALL show that message, as defined in `attachment-transfer`.

#### Scenario: Server rejection on upload shows the server's message
- **WHEN** the server answers the attachment POST with HTTP 400 and a JSON `message`
- **THEN** the add flow SHALL show "The server rejected the upload: <message>" inline

#### Scenario: Add Attachment button is always visible
- **WHEN** a vault item detail pane is shown
- **THEN** the Add Attachment button SHALL be visible regardless of the user's subscription status
