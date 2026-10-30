# Spec Delta

## ADDED Requirements

### Requirement: Master key derivation matches Bitwarden
The system SHALL derive the master key exactly as the Bitwarden SDK does: PBKDF2-SHA256 over the normalized salt, or Argon2id (version 0x13, 32-byte output) over the SHA-256 of the normalized salt with the server's memory value interpreted as MiB.

#### Scenario: SDK known-answer vectors
- **GIVEN** the PBKDF2 and Argon2id test vectors from the Bitwarden SDK (`kdf.rs` and `master_key.rs`)
- **WHEN** Prizm derives the master key and the server hash from the same inputs
- **THEN** every output SHALL equal the SDK's expected bytes

#### Scenario: Argon2id account signs in
- **GIVEN** an account on Vaultwarden 1.37.4 with Argon2id, 3 iterations, 64 MiB memory and parallelism 4
- **WHEN** the user signs in with the correct master password
- **THEN** the user SHALL reach the vault
- **AND** after locking, the same password SHALL unlock the vault offline

### Requirement: The email is normalized before use
The system SHALL trim surrounding whitespace from the email and lowercase it before using it for prelogin, as the KDF salt, and as the token request username.

#### Scenario: Email typed with spaces and capitals
- **GIVEN** an account registered as `user@example.com`
- **WHEN** the user types ` User@Example.com ` and the correct master password
- **THEN** the user SHALL reach the vault

### Requirement: The server salt is used when present
The system SHALL use the prelogin `salt` as the KDF salt when the server sends a non-empty value, and the normalized email otherwise, and SHALL use the same salt for offline unlock.

#### Scenario: Server without a salt
- **GIVEN** a prelogin response with `"salt": null`
- **WHEN** the master key is derived
- **THEN** the salt SHALL be the normalized email

#### Scenario: Unlock after an update from an older version
- **GIVEN** an account signed in before this change, so no salt is stored
- **WHEN** the user unlocks with the correct master password
- **THEN** the vault SHALL unlock, using the stored email as the salt

### Requirement: Unsafe KDF settings are refused
The system SHALL refuse to derive a key, on login and on unlock, when PBKDF2 has fewer than 5000 iterations, or Argon2id has fewer than 2 iterations, less than 16 MiB or more than 1024 MiB memory, or a parallelism below 1 or above 16, or when a value is missing, zero or negative. The system SHALL NOT offer to continue with such settings.

#### Scenario: Prelogin downgrade attempt
- **GIVEN** a server whose prelogin response says PBKDF2 with 1 iteration
- **WHEN** the user signs in
- **THEN** no request SHALL be sent to `/connect/token`
- **AND** the user SHALL see that the account's key-derivation settings are too weak and should be raised in the web vault, not "invalid credentials"
- **AND** VoiceOver SHALL read the message

#### Scenario: Argon2id memory allowed by the server but below the minimum
- **GIVEN** an account whose Argon2id memory is 15 MiB, which both servers accept
- **WHEN** the user signs in
- **THEN** no request SHALL be sent to `/connect/token`
- **AND** the user SHALL see the "too weak" error

#### Scenario: Malformed value
- **GIVEN** a prelogin response with a negative iteration count
- **WHEN** the user signs in
- **THEN** Prizm SHALL NOT crash
- **AND** the user SHALL see that the account's key-derivation settings can't be used by Prizm

### Requirement: Deprecated response fields are only a fallback
The system SHALL read KDF settings from `kdfSettings` in the prelogin response and the encrypted user key from `UserDecryptionOptions.MasterPasswordUnlock` in the token response, and SHALL read the flat `kdf*` fields and the top-level `Key` only when the new fields are absent, through separate legacy adapters.

#### Scenario: Server without the flat prelogin fields
- **GIVEN** a prelogin response with `kdfSettings` and no `kdf`, `kdfIterations`, `kdfMemory` or `kdfParallelism`
- **WHEN** the user signs in
- **THEN** the user SHALL reach the vault

#### Scenario: Server without kdfSettings or MasterPasswordUnlock
- **GIVEN** a Vaultwarden 1.34.0 server, whose prelogin has only flat `kdf*` fields and whose token response has only the top-level `Key`
- **WHEN** the user signs in with a PBKDF2 account
- **THEN** the user SHALL reach the vault

#### Scenario: New fields win over old ones
- **GIVEN** a prelogin response with both `kdfSettings` and flat fields that disagree
- **WHEN** the master key is derived
- **THEN** the `kdfSettings` values SHALL be used

#### Scenario: Stored settings are the ones that worked
- **GIVEN** a successful login
- **WHEN** Prizm stores the KDF settings for offline unlock
- **THEN** it SHALL store the settings and salt that decrypted the user key
- **AND** it SHALL NOT substitute a default iteration count for a missing value
