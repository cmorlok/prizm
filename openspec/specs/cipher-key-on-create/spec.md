# cipher-key-on-create Specification

## Purpose
Every item Prizm creates gets its own random encryption key, as in the official Bitwarden clients: the item's fields and attachments are encrypted with it, the key is stored wrapped with the user's or the organization's key, and the server's answer is used only when it carries that same key.

## Requirements

### Requirement: New items carry their own encryption key
When the user creates an item, the system SHALL generate a new random 64-byte item key, encrypt every field of the item with it, wrap it with the org key for an org item or the vault key otherwise, and send the wrapped key as `key` in the create request.

#### Scenario: Creating a personal login
- **GIVEN** an unlocked personal vault
- **WHEN** the user creates a login with a username, a password and a URI
- **THEN** the create request SHALL contain a non-empty `key`
- **AND** `key` SHALL decrypt with the vault key to 64 bytes
- **AND** every encrypted field in the request, including the URI checksum, SHALL decrypt with that item key and not with the vault key

#### Scenario: Creating an org login
- **GIVEN** the user is a member of an organization with access to a collection
- **WHEN** the user creates a login in that organization and collection
- **THEN** the create request SHALL contain a `key` that decrypts with the org key
- **AND** every encrypted field SHALL decrypt with the item key

#### Scenario: Every item type
- **GIVEN** an unlocked personal vault
- **WHEN** the user creates a card, an identity, a secure note or an SSH key with notes and a custom field
- **THEN** every encrypted field in the request, including the SSH key fingerprint and the custom field name and value, SHALL decrypt with the item key and not with the vault key

#### Scenario: Readable by official clients
- **GIVEN** a login created in Prizm with its own key
- **WHEN** an official Bitwarden client (browser extension or `bw` CLI) syncs
- **THEN** the item SHALL show the same name, username, password and URI as in Prizm

### Requirement: The new item key is usable before the next sync
After a successful create, the system SHALL make the item's own key available to attachment operations without waiting for a sync.

#### Scenario: Adding an attachment right after creating an item
- **GIVEN** the user just created an item in Prizm and no sync has run since
- **WHEN** the user adds an attachment to that item
- **THEN** the attachment key SHALL be wrapped with the item's own key
- **AND** after the next sync the attachment SHALL open in Prizm and in an official Bitwarden client

### Requirement: Creating an item never falls back to a weaker key setup
If generating or wrapping the item key fails, or the org key of an org item is unavailable, the system SHALL NOT create the item and SHALL show an error.

#### Scenario: Org key missing
- **GIVEN** an org item draft whose organization key is not available
- **WHEN** the user saves
- **THEN** no create request SHALL be sent
- **AND** the user SHALL see an error and the create sheet SHALL stay open with their input

#### Scenario: Key generation fails
- **GIVEN** the system random source fails
- **WHEN** the user saves a new item
- **THEN** no create request SHALL be sent
- **AND** the user SHALL see an error and the create sheet SHALL stay open with their input

### Requirement: The server's answer must carry the generated key
After a create, the system SHALL use the server's answer only if its `key` unwraps to the generated item key, its organization is the one sent, and it decrypts. Otherwise it SHALL NOT store, cache or list the answer, SHALL log the failure without key material, SHALL tell the user that the item was saved but could not be confirmed, and SHALL NOT offer Save again in that sheet.

#### Scenario: Answer without key
- **GIVEN** the server answers a create without `key`
- **WHEN** the create finishes
- **THEN** the item SHALL NOT appear in the list until the next sync
- **AND** the create sheet SHALL show "Saved, but Prizm couldn't confirm the new item. Sync to see it."
- **AND** Save SHALL be disabled

#### Scenario: Answer for another organization
- **GIVEN** the server answers a personal create with the generated `key` but an `organizationId`
- **WHEN** the create finishes
- **THEN** the item SHALL NOT be stored or listed until the next sync
- **AND** Save SHALL be disabled
