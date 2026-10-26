# uri-launch Specification

## Purpose
Open only website URIs with allow-listed schemes, and treat scheme-less addresses as http.

## Requirements

### Requirement: Only allow-listed schemes can be opened
The system SHALL offer "Open in browser" for a stored URI only when the URI, after the scheme-less rule, starts case-insensitively with one of `https://`, `http://`, `ssh://`, `ftp://`, `sftp://`, `irc://`, `vnc://`, `rdp://`, `ms-rd:`, `chrome://`, `iosapp://`, `androidapp://`, and its match type is not "Regular expression".

#### Scenario: Dangerous schemes in a shared item
- **GIVEN** an organization login whose URIs are `file:///Applications/Calculator.app`, `smb://server/share` and `x-custom-app://run`
- **WHEN** the user views the item
- **THEN** none of these website rows SHALL show an "Open in browser" button
- **AND** each URI SHALL still be shown and copyable

#### Scenario: Allowed schemes
- **GIVEN** a login with URIs `HTTPS://example.com` and `ssh://git.example.com`
- **WHEN** the user views the item
- **THEN** both rows SHALL show an "Open in browser" button
- **AND** VoiceOver SHALL read "Open Website" with the hint "Opens in browser"

#### Scenario: Regular-expression URI
- **GIVEN** a login URI `^https://.*\.example\.com/.*$` with match type "Regular expression"
- **WHEN** the user views the item
- **THEN** that row SHALL NOT show an "Open in browser" button

### Requirement: Scheme-less URIs open as http
When a stored URI has no `://` and its host is `localhost`, an IP address, or contains a dot, the system SHALL open it as `http://` followed by the URI.

#### Scenario: Imported URI without scheme
- **GIVEN** a login URI `example.com/login`
- **WHEN** the user clicks "Open in browser"
- **THEN** the default browser SHALL open `http://example.com/login`

#### Scenario: Bare word
- **GIVEN** a login URI `nas`
- **WHEN** the user views the item
- **THEN** that row SHALL NOT show an "Open in browser" button

### Requirement: No button without a handler
The system SHALL hide "Open in browser" for an allowed URI when no application on the Mac can open its scheme.

#### Scenario: Android app URI
- **GIVEN** a login URI `androidapp://com.example.app` and no app on the Mac handling `androidapp`
- **WHEN** the user views the item
- **THEN** that row SHALL NOT show an "Open in browser" button
