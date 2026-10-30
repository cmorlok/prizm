## MODIFIED Requirements

### Requirement: Attachment key encrypted with cipher key
The system SHALL encrypt the 64-byte attachment key with the item's effective key using AES-256-CBC + HMAC-SHA256, producing an EncString: the item's own key if it has one, otherwise the organization key for an organization item, otherwise the user's vault symmetric key (capability `attachment-key-resolution`). The system SHALL NOT use the user's vault symmetric key for an organization item. This encrypted attachment key SHALL be stored in the attachment metadata on the server.

#### Scenario: Encrypted attachment key is stored as EncString type 2
- **WHEN** an attachment key is wrapped for upload
- **THEN** the result SHALL be an EncString in `2.<iv_b64>|<ct_b64>|<mac_b64>` format

#### Scenario: Attachment key can be recovered from encrypted form using cipher key
- **WHEN** the encrypted attachment key is decrypted with the correct cipher key
- **THEN** the result SHALL be the original 64-byte attachment key
