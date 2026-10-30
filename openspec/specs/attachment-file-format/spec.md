# attachment-file-format Specification

## Purpose
Defines the byte layout of encrypted attachment files (the official Bitwarden EncArrayBuffer type 2), how Prizm reads files that Prizm 1.1.0 to 1.5.x wrote in its own layout, and how those files are converted to the official layout.

## Requirements

### Requirement: Attachment files use the official EncArrayBuffer layout
When Prizm uploads an attachment, the system SHALL encrypt the file as `0x02 ‖ IV(16) ‖ HMAC-SHA256(32) ‖ AES-256-CBC ciphertext`, with the HMAC computed over `IV ‖ ciphertext` using the attachment key's MAC half.

#### Scenario: Upload is readable by an official client
- **GIVEN** an unlocked vault and a login item the user can edit
- **WHEN** the user attaches a PDF in Prizm and an official Bitwarden client syncs
- **THEN** that client SHALL download and open the PDF with the same bytes as the original

#### Scenario: Byte layout
- **GIVEN** a 64-byte attachment key and a 10-byte plaintext
- **WHEN** Prizm encrypts the plaintext
- **THEN** the result SHALL be 65 bytes long
- **AND** byte 0 SHALL be `0x02`
- **AND** bytes 17 to 48 SHALL equal HMAC-SHA256 over bytes 1 to 16 followed by bytes 49 to 64

### Requirement: Attachment files from official clients and from older Prizm versions can be opened
The system SHALL decrypt an attachment blob in the official type-2 layout and in the layout written by Prizm 1.1.0 to 1.5.x (`IV ‖ ciphertext ‖ HMAC`). The system SHALL choose the layout from the blob length and type byte, and SHALL verify the HMAC before decrypting.

#### Scenario: Official known-answer vector
- **GIVEN** the 64-byte key and the 65-byte encrypted buffer from the Bitwarden SDK test `test_symmetric_decrypt_array_buffer`
- **WHEN** Prizm decrypts the buffer
- **THEN** the result SHALL be the bytes of `"test"`

#### Scenario: File uploaded by an older Prizm version
- **GIVEN** an attachment whose blob is `IV ‖ ciphertext ‖ HMAC` with a length that is a multiple of 16
- **WHEN** the user opens the attachment in Prizm
- **THEN** the file SHALL open
- **AND** this SHALL also hold when the first IV byte happens to be `0x02`

#### Scenario: Tampered file
- **GIVEN** an attachment blob in either layout with one ciphertext byte changed
- **WHEN** the user opens it
- **THEN** no plaintext SHALL be produced
- **AND** the user SHALL see that the file could not be decrypted

### Requirement: Unauthenticated and malformed attachment files are refused
The system SHALL refuse to decrypt a blob of type `0x00`, any other type byte, or a length that matches neither supported layout.

#### Scenario: Type 0 blob
- **GIVEN** a blob `0x00 ‖ IV ‖ ciphertext` with no MAC
- **WHEN** the user opens the attachment
- **THEN** Prizm SHALL NOT decrypt it
- **AND** the user SHALL see that the file uses an unsupported format

### Requirement: Old-format attachments can be converted
For an attachment whose encrypted size is a multiple of 16, or an organization attachment wrapped with the personal key, the system SHALL offer to convert it. Conversion SHALL re-upload the file in the official layout as a new attachment with a new attachment key and the same file name, and SHALL delete the old attachment only after the new upload succeeded.

#### Scenario: Converting one attachment
- **GIVEN** an item the user can edit with an attachment uploaded by Prizm 1.5.0
- **WHEN** the user chooses "Convert" on that attachment
- **THEN** the item SHALL have one attachment with the same file name and contents
- **AND** that attachment SHALL open in an official Bitwarden client

#### Scenario: Upload fails during conversion
- **GIVEN** a conversion in progress
- **WHEN** the upload of the new file fails
- **THEN** the new attachment record SHALL be deleted
- **AND** the old attachment SHALL remain unchanged and still open in Prizm
- **AND** the user SHALL see an error naming the file

#### Scenario: Convert all after sync
- **GIVEN** a sync that returned three editable attachments with sizes that are multiples of 16
- **WHEN** the sync finishes
- **THEN** Prizm SHALL show a notice once per unlock offering "Convert all" and "Later"
- **AND** choosing "Convert all" SHALL convert the files one at a time and report progress and failures

#### Scenario: Server refuses the conversion
- **GIVEN** an old-format attachment on an item the server does not let the user change
- **WHEN** the user chooses "Convert" and the server refuses the upload
- **THEN** the old attachment SHALL remain unchanged and still open in Prizm
- **AND** the user SHALL see the server's message
- **AND** VoiceOver SHALL read that the file is in the old Prizm format and other Bitwarden apps can't open it

#### Scenario: Org attachment wrapped with the personal key
- **GIVEN** an organization item without its own key and an attachment that Prizm 1.5.0 wrapped with the user's vault key
- **WHEN** the user converts it
- **THEN** the new attachment key SHALL be wrapped with the organization key
- **AND** the "Only you can open this file" note SHALL no longer be shown
