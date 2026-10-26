# prelogin-endpoint Specification

## Purpose
Read the account KDF settings from the Identity prelogin endpoint, with a fallback for older servers.

## Requirements

### Requirement: Prelogin uses the identity service
The system SHALL request the account's KDF settings with `POST {base}/identity/accounts/prelogin/password` and a JSON body containing the email, and SHALL NOT call `{base}/api/accounts/prelogin`.

#### Scenario: Login on Vaultwarden 1.37.4
- **GIVEN** a PBKDF2 account on a Vaultwarden 1.37.4 server
- **WHEN** the user enters the server URL, email and correct master password and signs in
- **THEN** the prelogin request SHALL go to `{base}/identity/accounts/prelogin/password`
- **AND** no request SHALL go to `{base}/identity/accounts/prelogin`
- **AND** the user SHALL reach the vault

#### Scenario: Login on a Bitwarden self-hosted server
- **GIVEN** a PBKDF2 account on a current Bitwarden self-hosted server
- **WHEN** the user signs in with the correct master password
- **THEN** the user SHALL reach the vault

### Requirement: Older servers use the legacy prelogin route
The system SHALL send the same request to `POST {base}/identity/accounts/prelogin` only when the primary route answers HTTP 404 or 405, through a separate legacy adapter, and SHALL NOT fall back on any other failure.

#### Scenario: Login on Vaultwarden 1.35.4
- **GIVEN** a PBKDF2 account on a Vaultwarden 1.35.4 server, which has no `/identity/accounts/prelogin/password` route
- **WHEN** the user signs in with the correct master password
- **THEN** the first prelogin request SHALL get 404
- **AND** a second request SHALL go to `{base}/identity/accounts/prelogin`
- **AND** the user SHALL reach the vault

#### Scenario: Server error is not hidden
- **GIVEN** a server whose primary prelogin route answers HTTP 500
- **WHEN** the user signs in
- **THEN** no request SHALL go to `{base}/identity/accounts/prelogin`
- **AND** the user SHALL see the server error as today

### Requirement: Prelogin responses from both servers decode
The system SHALL decode the prelogin response of Vaultwarden 1.32.0 to 1.37.4 and of the official server into the same KDF parameters as before this change.

#### Scenario: Response with kdfSettings and a null salt
- **GIVEN** a prelogin response with the flat `kdf`, `kdfIterations`, `kdfMemory` and `kdfParallelism` fields, a `kdfSettings` object and `"salt": null`
- **WHEN** Prizm decodes it
- **THEN** decoding SHALL succeed
- **AND** the KDF type and iteration count SHALL equal the flat fields
