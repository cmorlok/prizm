## MODIFIED Requirements

### Requirement: Open decrypts and opens attachment in default app
Each attachment row SHALL have an "Open" action. Pressing it SHALL:
1. Download and decrypt the attachment on a background `Task`
2. Write the plaintext bytes to a temp file in the dedicated folder defined in `attachment-transfer` ("Decrypted temp files do not outlive the session")
3. Open the temp file via `NSWorkspace.shared.open(_:)`
4. After 30 seconds, overwrite the temp file with zeroes and delete it

A row-level progress indicator SHALL be shown during download and decryption. If the operation fails, an inline error SHALL appear on the row; if the server has no file for the attachment, the row SHALL show the missing-file state defined in `attachment-transfer` instead.

#### Scenario: Open downloads, decrypts, and launches default app
- **WHEN** the user clicks "Open" on an attachment row
- **THEN** the system SHALL download and decrypt the file in the background and open it with the system default app for its file type

#### Scenario: Temp file is zeroed and deleted 30 seconds after open
- **WHEN** 30 seconds have elapsed after the temp file was written
- **THEN** the temp file SHALL be overwritten with zeroes and deleted

#### Scenario: Open failure shows inline row error
- **WHEN** download or decryption fails
- **THEN** an inline error SHALL appear on the attachment row; no temp file SHALL remain on disk

## REMOVED Requirements

### Requirement: Upload-incomplete attachments are shown with retry option
**Reason**: No server marks an attachment as incomplete (the sync `url` is never nil for such a record), so the state never appeared, and a failed upload now deletes its record (`attachment-transfer`, "Failed uploads are rolled back").
**Migration**: An attachment whose file is missing on the server shows "The file is missing on the server" with Delete when the user opens it (`attachment-transfer`, "Downloads use a fresh URL"). To replace the file, delete the entry and add the file again.
