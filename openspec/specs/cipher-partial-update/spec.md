# cipher-partial-update Specification

## Purpose
Save favorite and folder changes as partial updates that leave all other item data untouched.

## Requirements

### Requirement: Toggling favorite sends a partial update only
When the user toggles the favorite state of an item from the detail toolbar or the list context menu, the system SHALL send `PUT /api/ciphers/{id}/partial` with the new `favorite` value and the item's current `folderId`, and SHALL NOT send `PUT /api/ciphers/{id}` or any collections request. After that request succeeds, the system SHALL fetch the item once with `GET /api/ciphers/{id}` to learn its current record and revision.

#### Scenario: Favorite a login with a passkey
- **GIVEN** a login created in the Bitwarden browser extension with a passkey and password history
- **WHEN** the user clicks the favorite star in Prizm
- **THEN** one `PUT /api/ciphers/{id}/partial` with `favorite: true` and the item's `folderId` SHALL be sent, followed by one `GET /api/ciphers/{id}` of the item, and no other request
- **AND** after the next sync the extension SHALL still show the passkey and the password history

#### Scenario: Favorite a read-only org item
- **GIVEN** an org item in a collection where the user has view-only access
- **WHEN** the user clicks the favorite star
- **THEN** the request SHALL succeed and the item SHALL appear under Favorites

#### Scenario: Favorite toggle fails
- **GIVEN** the partial request returns an error
- **WHEN** the user clicks the favorite star
- **THEN** an error alert SHALL be shown and announced to VoiceOver
- **AND** the item's favorite state SHALL stay unchanged

### Requirement: Local favorite and folder changes keep all other item data
After a favorite change, a move to a folder (single or bulk), or a folder deletion, the system SHALL update only the changed field of the cached item and SHALL keep every other field, including `organizationId`, `collectionIds`, `attachments` and `reprompt`. The cached `revisionDate` SHALL change only as the revision refresh decides (`vault-item-edit-roundtrip`, "Prizm's own changes do not cause a false conflict"): to the revision of the record fetched after the change when the item's content is unchanged, otherwise not.

#### Scenario: Move an org item to a folder, then edit it
- **GIVEN** an org item in collection "A"
- **WHEN** the user moves it to folder "Work" and then edits its password and saves, without a sync in between
- **THEN** the item SHALL still be listed under collection "A"
- **AND** the save SHALL succeed and SHALL be encrypted with the organization key

#### Scenario: Delete a folder that contains an org item
- **GIVEN** an org item in folder "Old" and collection "A"
- **WHEN** the user deletes folder "Old"
- **THEN** the item SHALL have no folder and SHALL still belong to its organization and collection "A"

#### Scenario: Revision date after a partial update
- **GIVEN** an item with revision date R, and a server that reports revision R2 for the item after the change (R2 equals R when the server does not change it)
- **WHEN** the user toggles its favorite state or moves it to a folder
- **THEN** the cached revision date SHALL be R2

#### Scenario: Item changed on another device
- **GIVEN** an item with revision date R whose content another client changed after Prizm's last sync
- **WHEN** the user toggles its favorite state or moves it to a folder
- **THEN** the change SHALL be applied
- **AND** the cached revision date SHALL still be R, so that the next edit of the item is rejected as a conflict
