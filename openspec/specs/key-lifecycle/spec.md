# key-lifecycle Specification

## Purpose
Zero transient key material, tear all keys down in one place, and keep secrets out of logs.

## Requirements

### Requirement: Sign-out clears all key material
The system SHALL zero and clear the vault key, every cached item key and every cached organization key when the user signs out, by any route, through the same code path as locking.

#### Scenario: Sign out from an unlocked vault with organizations
- **GIVEN** an unlocked vault with items from two organizations
- **WHEN** the user signs out from the menu
- **THEN** the organization key cache SHALL be empty
- **AND** the buffers of the removed organization keys SHALL contain only zeros

#### Scenario: Sign in with a different account from the unlock screen
- **GIVEN** the unlock screen of an account that belongs to an organization
- **WHEN** the user chooses "Sign in with a different account"
- **THEN** no key of the previous account SHALL remain in the vault key, item key or organization key caches

### Requirement: Organization keys follow the latest sync
After each sync that completes, the organization key cache SHALL hold keys only for organizations in that sync response whose keys could be unwrapped. The cache SHALL be replaced in one step (`fix-org-key-required-on-write`), never cleared before the new keys are ready. A sync that fails as a whole SHALL leave the previous keys, as it leaves the previous items.

#### Scenario: User left their last organization
- **GIVEN** a previous sync stored the key of organization A
- **WHEN** a new sync returns no organizations
- **THEN** the organization key cache SHALL be empty
- **AND** no item of organization A SHALL be shown

#### Scenario: Private key cannot be decrypted
- **GIVEN** a previous sync stored organization keys
- **WHEN** a new sync returns a private key that fails to decrypt
- **THEN** the organization key cache SHALL be empty

### Requirement: Transient keys are zeroed after use
The system SHALL zero the master key, the stretched keys, the decrypted user-key buffer and the keys held during a two-factor step as soon as they are no longer needed, on success, error, cancel and sign-out.

#### Scenario: Login with two-factor authentication
- **GIVEN** a login that requires a TOTP code
- **WHEN** the user enters a valid code and reaches the vault
- **THEN** the stretched keys kept for the two-factor step SHALL contain only zeros
- **AND** the vault SHALL decrypt normally

#### Scenario: Failed unlock
- **GIVEN** the unlock screen
- **WHEN** the user enters a wrong master password
- **THEN** the master key and stretched keys derived for that attempt SHALL contain only zeros

### Requirement: Debug logs contain no identifying secrets
When debug mode is on, the system SHALL NOT log the email, two-factor code, device identifier, tokens or password hash, and SHALL mark any logged server-provided text as private.

#### Scenario: Debug login with 2FA
- **GIVEN** Prizm started with `--debug-mode`
- **WHEN** the user logs in with a TOTP code
- **THEN** the unified log SHALL NOT contain the email or the TOTP code as public data

### Requirement: SECURITY.md matches the key lifecycle
The project SHALL document in SECURITY.md when each key is zeroed, that the device identifier is kept on sign-out, how biometric unlock compares with the official iOS and desktop apps, and the limits of zeroing memory in Swift.

#### Scenario: Reviewer checks the device identifier claim
- **GIVEN** SECURITY.md after this change
- **WHEN** a reviewer compares the device identifier row with `AuthRepositoryImpl.signOut()`
- **THEN** both SHALL say the identifier is kept on sign-out
