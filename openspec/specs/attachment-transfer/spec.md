# attachment-transfer Specification

## Purpose
Defines how attachment uploads and downloads recover from server failures: failed uploads are rolled back, downloads use a fresh URL, server rejections show the server's message, item metadata is refreshed from the server's answer, and decrypted temp files are removed when the session ends.

## Requirements

### Requirement: Failed uploads are rolled back
When an attachment upload fails or is cancelled after the server created the attachment record, the system SHALL delete that record with `DELETE /api/ciphers/{id}/attachment/{attachmentId}` before reporting the failure.

#### Scenario: Storage limit reached on Vaultwarden
- **GIVEN** a Vaultwarden account at its attachment storage limit
- **WHEN** the user adds a file to an item
- **THEN** Prizm SHALL send the DELETE for the new attachment ID
- **AND** the item SHALL show no new attachment, in Prizm and after a sync in the Bitwarden browser extension
- **AND** the user SHALL see the server's message about the storage limit

#### Scenario: User cancels during upload
- **GIVEN** an upload in progress after the metadata request succeeded
- **WHEN** the user cancels
- **THEN** the DELETE SHALL still be sent and the item SHALL show no new attachment

#### Scenario: Rollback fails
- **GIVEN** the file upload failed and the network is gone
- **WHEN** the DELETE for the new attachment fails as well
- **THEN** the user SHALL see that the upload failed and that a broken attachment entry may remain and can be deleted

### Requirement: Downloads use a fresh URL
Before downloading an attachment, the system SHALL request a fresh download URL with `GET /api/ciphers/{id}/attachment/{attachmentId}`, and SHALL use the URL from the sync only if that request returns 404.

#### Scenario: Download long after sync on Vaultwarden
- **GIVEN** a Vaultwarden 1.37.4 vault that synced 10 minutes ago
- **WHEN** the user opens an attachment
- **THEN** the file SHALL download and open

#### Scenario: File missing on the server
- **GIVEN** an attachment record whose file does not exist on the server
- **WHEN** the user opens it
- **THEN** the user SHALL see "The file is missing on the server" with an option to delete the attachment
- **AND** VoiceOver SHALL read the message and the delete option

### Requirement: Server rejections show the server's message
When the server rejects an attachment request with HTTP 400 and a JSON `message`, the system SHALL show that message to the user.

#### Scenario: Premium required on Bitwarden self-hosted
- **GIVEN** a Bitwarden self-hosted account without premium
- **WHEN** the user adds a file to a personal item
- **THEN** the add sheet SHALL show "The server rejected the upload: You must have premium status to use attachments."

### Requirement: Item metadata is refreshed after attachment changes
After a successful attachment upload or delete, the system SHALL update the item's revision date and attachment list from the item returned by the server.

#### Scenario: Older server without the item in the delete response
- **GIVEN** a server that answers an attachment delete with an empty body, such as Vaultwarden 1.32.0
- **WHEN** the user deletes an attachment
- **THEN** the delete SHALL succeed
- **AND** the attachment SHALL no longer be listed

#### Scenario: Edit after adding an attachment
- **GIVEN** the user added an attachment to an item
- **WHEN** the user then edits and saves that item without syncing
- **THEN** the save SHALL succeed
- **AND** the item's revision date in Prizm SHALL equal the one the server returned for the attachment upload

### Requirement: Decrypted temp files do not outlive the session
The system SHALL write files opened from attachments only to a dedicated temporary folder, and SHALL overwrite and delete every file in that folder when the vault locks, when the user signs out, when the app quits, and when the app launches.

#### Scenario: Lock right after opening a file
- **GIVEN** the user opened a PDF attachment in Preview 5 seconds ago
- **WHEN** the vault locks
- **THEN** the folder SHALL contain no files

#### Scenario: Crash after opening a file
- **GIVEN** Prizm crashed while a decrypted file was in the folder
- **WHEN** Prizm launches again
- **THEN** the folder SHALL be emptied before the login or unlock screen appears

### Requirement: Multipart upload names the part like official clients
For direct uploads, the system SHALL send the encrypted file name EncString as the `filename` of the `data` part.

#### Scenario: Multipart body
- **GIVEN** a direct upload (`fileUploadType` 0)
- **WHEN** Prizm builds the multipart body
- **THEN** the `Content-Disposition` of part `data` SHALL carry `filename="<encrypted file name>"`
