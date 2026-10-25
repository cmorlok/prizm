# Spec Delta

## ADDED Requirements

### Requirement: Symmetric decryption requires an authenticated EncString
The system SHALL decrypt symmetric vault data (fields, item keys, folder and collection names, attachment keys and names, the user key, the private key) only from EncString type 2, SHALL verify its HMAC-SHA256 before any AES decryption, and SHALL NOT decrypt EncString type 0 on any path.

#### Scenario: MAC stripped by the server
- **GIVEN** a cipher whose name was rewritten from `2.<iv>|<ct>|<mac>` to `0.<iv>|<ct>`
- **WHEN** Prizm syncs
- **THEN** the cipher's content SHALL NOT be shown
- **AND** it SHALL be counted as a failed item
- **AND** no AES decryption SHALL be attempted for that field

#### Scenario: Attachment name without MAC
- **GIVEN** a listed item one of whose attachments has a file name of type 0
- **WHEN** Prizm syncs
- **THEN** that attachment SHALL NOT be shown and an error SHALL be logged
- **AND** the item and its other attachments SHALL be shown

#### Scenario: RSA type used where a symmetric value is expected
- **GIVEN** a cipher field of the form `4.<a>|<b>|<c>` or `6.<a>`
- **WHEN** Prizm decrypts the field
- **THEN** decryption SHALL fail with an unsupported-type error

### Requirement: EncString lengths are checked
The system SHALL reject a type-2 EncString unless it has exactly three parts, a 16-byte IV, a 32-byte MAC and a non-empty ciphertext whose length is a multiple of 16.

#### Scenario: Short IV
- **GIVEN** a type-2 EncString whose IV decodes to 8 bytes and whose MAC is otherwise valid
- **WHEN** Prizm parses it
- **THEN** parsing SHALL fail with `invalidIVLength`
- **AND** no AES call SHALL be made

### Requirement: Malformed private keys do not crash the app
The system SHALL check every DER length in the PKCS#8 private key against the remaining bytes and SHALL fail with a malformed-private-key error, not a crash, on malformed input.

#### Scenario: Truncated private key
- **GIVEN** a decrypted private key whose DER length field claims more bytes than are present
- **WHEN** Prizm unwraps organization keys
- **THEN** unwrapping SHALL fail with an error
- **AND** the app SHALL keep running and show the personal vault

### Requirement: Key stretching is documented and tested against CryptoKit
The system SHALL stretch the master key with HKDF-Expand (RFC 5869 §2.3) without Extract, and its output SHALL equal CryptoKit `HKDF<SHA256>.expand` and the Bitwarden SDK test vector.

#### Scenario: Stretch known answer
- **GIVEN** the master key from the SDK `test_stretch_kdf_key` vector
- **WHEN** Prizm stretches it
- **THEN** the encryption and MAC keys SHALL equal the SDK's expected values
- **AND** they SHALL equal the output of `HKDF<SHA256>.expand` with info `enc` and `mac`
