## MODIFIED Requirements

### Requirement: Upload runs on a background task with progress indicator
Encryption and upload SHALL execute on a background `Task`. While in progress, the confirmation sheet SHALL show a progress indicator and disable the Confirm button; the Cancel button SHALL remain enabled. On success, the sheet SHALL dismiss. On failure, the sheet SHALL remain open with an inline error.

#### Scenario: Progress indicator shown during upload
- **WHEN** the user confirms and upload begins
- **THEN** a progress indicator SHALL be visible and the Confirm button SHALL be disabled; Cancel SHALL remain enabled

#### Scenario: Cancel during upload aborts and clears file data
- **WHEN** the user presses Cancel while upload is in progress
- **THEN** the upload task SHALL be cancelled, the in-memory file data buffer SHALL be zeroed, and the sheet SHALL dismiss immediately

#### Scenario: Upload failure shows inline error with Cancel enabled
- **WHEN** the upload fails (network error, server error, server rejection)
- **THEN** the confirmation sheet SHALL remain open with an inline error message and Cancel SHALL be enabled

#### Scenario: Server rejection shown inline
- **WHEN** the server rejects the upload with HTTP 400 and a JSON `message`
- **THEN** "The server rejected the upload: <message>" SHALL be shown on the confirmation sheet

---

### Requirement: Batch confirmation sheet for drag-and-drop uploads
When files are dropped, the system SHALL present a single sheet listing all dropped files before any upload begins. Each file SHALL appear as a row showing its name and `sizeName`. Files exceeding 500 MB SHALL show an inline per-row error ("Too large — 500 MB max") and SHALL be excluded from the upload. The Confirm button SHALL be enabled if at least one dropped file is valid; it SHALL be disabled only if every file exceeds the limit. Confirming SHALL encrypt and upload all valid files concurrently on background `Task`s. The sheet SHALL remain open showing per-file upload state until all uploads complete or fail, then dismiss automatically on full success or remain open to show failures.

#### Scenario: Batch sheet lists all dropped files with name and size
- **WHEN** the batch confirmation sheet opens after a drop
- **THEN** every dropped file SHALL appear as a row showing its file name and `sizeName`

#### Scenario: Oversized files are flagged inline but do not block valid files
- **WHEN** the batch sheet contains a mix of valid files and files over 500 MB
- **THEN** each oversized file row SHALL show "Too large — 500 MB max" and SHALL be marked as excluded
- **AND** the Confirm button SHALL be enabled for the remaining valid files

#### Scenario: Confirm is disabled when every dropped file exceeds 500 MB
- **WHEN** all files in the batch sheet exceed 500 MB
- **THEN** the Confirm button SHALL be disabled

#### Scenario: Confirming starts concurrent uploads for all valid files
- **WHEN** the user confirms the batch sheet
- **THEN** each valid file SHALL begin encrypting and uploading on its own background `Task` concurrently
- **AND** each row SHALL show an individual progress indicator

#### Scenario: Per-file upload success removes the progress indicator from that row
- **WHEN** a file in the batch uploads successfully
- **THEN** its row SHALL show a success indicator and the attachment SHALL appear in the detail pane

#### Scenario: Per-file upload failure shows an inline row error
- **WHEN** a file in the batch fails to upload
- **THEN** its row SHALL show an inline error message; other files in the batch are not affected

#### Scenario: Sheet dismisses automatically when all uploads succeed
- **WHEN** every valid file in the batch has uploaded successfully
- **THEN** the sheet SHALL dismiss and all new attachments SHALL be visible in the Attachments section

#### Scenario: Sheet stays open if any upload fails
- **WHEN** at least one file in the batch fails to upload
- **THEN** the sheet SHALL remain open showing the failure rows; the user SHALL be able to dismiss manually

#### Scenario: Cancel before confirming discards all dropped file data
- **WHEN** the user presses Cancel on the batch confirmation sheet before confirming
- **THEN** no uploads SHALL be initiated and all in-memory file references SHALL be released

#### Scenario: Cancel while uploads are in progress cancels all tasks
- **WHEN** the user presses Cancel on the batch confirmation sheet after confirming (while uploads are running)
- **THEN** all in-flight upload tasks SHALL be cancelled, in-memory file bytes SHALL be zeroed, and the sheet SHALL dismiss immediately; the attachment record of every cancelled upload SHALL be deleted again (`attachment-transfer`, "Failed uploads are rolled back")
