# uri-checksum-validation Specification

## Purpose
For an item with its own key, Prizm checks each website against its encrypted checksum, as the official Bitwarden clients do, so a server cannot swap a login's website for another; a website whose checksum fails is not shown or used, and the item says how many were hidden.

## Requirements

### Requirement: URIs of keyed items are verified before use
For a login that has its own item key, the system SHALL keep a URI only if the URI has a value and a `uriChecksum` that decrypts to the standard base64 encoding of SHA-256 over the URI's UTF-8 bytes, compared in constant time. All other URIs SHALL be removed from the decrypted item before display, search, icon lookup or AutoFill.

#### Scenario: Checksum does not match
- **GIVEN** a keyed login with URI "https://example.com" whose checksum decrypts to the hash of "https://evil.example"
- **WHEN** Prizm syncs
- **THEN** the login SHALL show no URI "https://example.com"
- **AND** searching for "example.com" SHALL NOT find the login through that URI

#### Scenario: Checksum missing
- **GIVEN** a keyed login with a URI that has no `uriChecksum`
- **WHEN** Prizm syncs
- **THEN** that URI SHALL NOT be shown

#### Scenario: Valid checksum
- **GIVEN** a keyed login with URI "https://example.com" and checksum `EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk=`
- **WHEN** Prizm syncs
- **THEN** the URI SHALL be shown

#### Scenario: Unkeyed item
- **GIVEN** a login without its own item key and a URI without a `uriChecksum`
- **WHEN** Prizm syncs
- **THEN** the URI SHALL be shown

### Requirement: Hidden URIs are reported, not silent
When URIs are removed by the checksum check, the system SHALL show in the item detail how many websites were hidden because they failed an integrity check, SHALL make that notice readable by VoiceOver, and SHALL log the item ID and count without the URI.

#### Scenario: Notice in the detail pane
- **GIVEN** a keyed login with one URI removed by the checksum check
- **WHEN** the user opens the login
- **THEN** the detail pane SHALL show "1 website hidden because it failed an integrity check"

#### Scenario: Every website removed
- **GIVEN** a keyed login whose only two URIs were both removed by the checksum check
- **WHEN** the user opens the login
- **THEN** the detail pane SHALL show "2 websites hidden because they failed an integrity check"
- **AND** SHALL show no website row

### Requirement: Removed URIs are not written back
When the user saves a login from which URIs were removed by the checksum check, the system SHALL send only the remaining URIs, each with a freshly computed checksum.

#### Scenario: Editing after removal
- **GIVEN** a keyed login with two URIs, one of which was removed by the checksum check
- **WHEN** the user changes the username and saves
- **THEN** the update request SHALL contain exactly one URI
- **AND** its `uriChecksum` SHALL decrypt to the hash of that URI
