# client-identification Specification

## Purpose
Identify Prizm to the server as a macOS desktop client on every request, and to no other host.

## Requirements

### Requirement: Identification headers on every server request
Every request to the configured server's API and identity endpoints SHALL include `Device-Type: 7`, `Bitwarden-Client-Name: desktop` and `Bitwarden-Client-Version` with the compatibility version defined in `Config`.

#### Scenario: Sync request
- **GIVEN** an unlocked vault
- **WHEN** Prizm requests `/api/sync`
- **THEN** the request SHALL carry `Device-Type: 7`, `Bitwarden-Client-Name: desktop` and `Bitwarden-Client-Version: 2024.12.0`

#### Scenario: Unauthenticated prelogin and token requests
- **WHEN** Prizm sends the prelogin request and the password token request
- **THEN** both requests SHALL carry the same three headers
- **AND** the token request SHALL still send the form fields `client_id=desktop` and `deviceType=7`

#### Scenario: Vaultwarden event log
- **GIVEN** organization event logging is enabled on Vaultwarden
- **WHEN** a Prizm user edits an organization item
- **THEN** the event SHALL be recorded with device type macOS desktop, not Unknown Browser

### Requirement: No nonstandard or misleading identification
Requests SHALL NOT include an `X-Client-Version` header. The `User-Agent` header SHALL name Prizm with its own app version and the macOS version, and SHALL NOT contain the Bitwarden compatibility version.

#### Scenario: User agent
- **GIVEN** Prizm 1.6.0 running on macOS 26.1
- **WHEN** any request is sent to the server
- **THEN** `User-Agent` SHALL be `Prizm/1.6.0 (macOS 26.1.0)`
- **AND** no `X-Client-Version` header SHALL be present

### Requirement: Identification stays with the configured server
Requests to hosts other than the configured server, such as attachment blob storage and website icon requests, SHALL NOT include `Device-Type`, `Bitwarden-Client-Name`, `Bitwarden-Client-Version` or an `Authorization` header.

#### Scenario: Azure attachment upload
- **WHEN** Prizm uploads an attachment to a signed Azure blob URL
- **THEN** the upload request SHALL carry none of the Bitwarden identification headers

### Requirement: Device name is Prizm
The token request SHALL send `deviceName=Prizm`, so that users can tell Prizm apart from the official desktop app in the server's device list. This is a documented difference from the official macOS desktop app, which sends `macos`.

#### Scenario: Device list in the web vault
- **GIVEN** the user signed in with Prizm and with the official desktop app on the same Mac
- **WHEN** the user opens the device list in the web vault
- **THEN** the Prizm session SHALL be listed with the name "Prizm"
