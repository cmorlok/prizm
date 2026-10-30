## MODIFIED Requirements

### Requirement: File data encrypted with attachment key
The system SHALL encrypt attachment file data using the AES-256-CBC + HMAC-SHA256 algorithm with the per-attachment key. The encrypted output SHALL be transmitted as **raw binary**, NOT as a Base64-encoded EncString string. Its byte layout is defined by the capability `attachment-file-format` (the official EncArrayBuffer type 2, `0x02 ‖ IV(16) ‖ HMAC-SHA256(32) ‖ ciphertext`), which supersedes the layout `16-byte IV ‖ ciphertext ‖ 32-byte HMAC` this requirement stated before; only Prizm 1.1.0 to 1.5.x wrote that layout. EncString (Base64-encoded, `2.<iv>|<ct>|<mac>`) is used only for metadata fields (attachment key and file name). MAC SHALL be verified before decryption (Encrypt-then-MAC).

#### Scenario: File data is not stored or transmitted in plaintext
- **WHEN** an attachment is prepared for upload
- **THEN** the bytes written to the upload stream SHALL be the AES-256-CBC ciphertext, not the original file data

#### Scenario: MAC verification prevents tampered ciphertext from decrypting
- **WHEN** any byte of the encrypted blob is modified and decryption is attempted
- **THEN** the system SHALL throw a MAC verification error and SHALL NOT return any plaintext bytes

#### Scenario: Round-trip encrypt then decrypt returns original bytes
- **WHEN** a file is encrypted with an attachment key and then decrypted with the same key
- **THEN** the decrypted bytes SHALL be identical to the original file bytes
