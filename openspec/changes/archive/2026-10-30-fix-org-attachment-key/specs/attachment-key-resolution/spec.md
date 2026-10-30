# Spec Delta

## ADDED Requirements

### Requirement: Attachments use the item's effective key
For attachment upload and download, the system SHALL use the item's own key if it has one, otherwise the organization key for an organization item, otherwise the personal vault key. The system SHALL NOT use the personal vault key for an organization item.

#### Scenario: Upload to a synced org item without its own key
- **GIVEN** an organization item without its own key, loaded by the last sync
- **WHEN** the user adds an attachment
- **THEN** the attachment key and the file name SHALL be encrypted with the organization key
- **AND** another member of the organization SHALL be able to open the file in an official Bitwarden client

#### Scenario: Attachment on a new org item before the next sync
- **GIVEN** the user just created an organization item in Prizm and no sync has run since
- **WHEN** the user adds an attachment to it
- **THEN** the attachment key SHALL be encrypted with the organization key
- **AND** after the next sync the attachment SHALL still be listed and open in Prizm

#### Scenario: Personal item without its own key
- **GIVEN** a personal item without its own key
- **WHEN** the user adds and then opens an attachment
- **THEN** the attachment key SHALL be encrypted with the vault key and the file SHALL open

### Requirement: Missing keys fail instead of falling back
If the organization key of an organization item is not available, or the item is unknown to the key cache, the system SHALL NOT perform the attachment operation and SHALL show an error.

#### Scenario: Org key missing
- **GIVEN** an organization item listed by an earlier sync whose organization key is no longer available (the organization pass of the latest sync failed, or the user left the organization)
- **WHEN** the user tries to add an attachment
- **THEN** no request SHALL be sent to the server
- **AND** the user SHALL see that the organization key is not available

#### Scenario: Unknown item
- **GIVEN** a cipher ID that is not in the key cache
- **WHEN** an attachment download is requested for it
- **THEN** the operation SHALL fail with a "key unavailable" error and SHALL NOT use the vault key

### Requirement: Attachments saved with the personal key are found and kept
For an organization item without its own key, when an attachment's file name does not decrypt with the organization key but does decrypt with the personal vault key, the system SHALL keep the attachment in the item, mark it as readable only by this user, and SHALL open it using the personal vault key.

#### Scenario: Attachment uploaded by Prizm 1.5.0 to an org item
- **GIVEN** an org item without its own key and an attachment whose key and file name were encrypted with the user's vault key
- **WHEN** the vault syncs
- **THEN** the attachment SHALL appear in the item with its file name
- **AND** the row SHALL say that only this user can open the file and offer to convert it
- **AND** VoiceOver SHALL read the same warning
- **AND** opening the attachment SHALL show its contents

#### Scenario: Attachment that decrypts with neither key
- **GIVEN** an org attachment whose file name decrypts with neither the org key nor the vault key
- **WHEN** the vault syncs
- **THEN** the attachment SHALL be left out of the item and an error SHALL be logged without the file name
