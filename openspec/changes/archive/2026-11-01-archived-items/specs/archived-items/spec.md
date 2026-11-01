# Spec Delta

## ADDED Requirements

### Requirement: Archived items are kept out of the everyday lists
The system SHALL read each item's `archivedDate` from the sync response and SHALL exclude items with a non-null `archivedDate` from All Items, Favorites, the type lists, folders, collections, organizations, the Codes list and search outside the Archive view.

#### Scenario: Item archived in another client
- **GIVEN** a sync response in which a login has a non-null `archivedDate` (archived in another client)
- **WHEN** Prizm syncs
- **THEN** the login SHALL NOT appear in All Items, Logins, Favorites or its folder
- **AND** the All Items count SHALL NOT include it

### Requirement: An Archive view lists archived items
The system SHALL offer an "Archive" sidebar entry that lists items that are archived and not deleted, with a count, and SHALL keep listing deleted items in Trash whether or not they are archived.

#### Scenario: Archived and deleted
- **GIVEN** item A is archived, and item B is archived and in the trash
- **WHEN** the user opens Archive
- **THEN** only item A SHALL be listed
- **WHEN** the user opens Trash
- **THEN** item B SHALL be listed

#### Scenario: Last archived item unarchived while Archive is selected
- **GIVEN** Archive is selected and lists one item
- **WHEN** the user unarchives it
- **THEN** the Archive entry SHALL disappear, the selection SHALL fall back to All Items
- **AND** the item SHALL stay selected there

#### Scenario: Restoring an archived item from Trash
- **GIVEN** item B is archived and in the trash
- **WHEN** the user restores it and the server's restored record still carries its `archivedDate`
- **THEN** it SHALL appear in Archive and not in All Items

### Requirement: Users can archive and unarchive items
The system SHALL archive an item with `PUT /api/ciphers/{id}/archive` and unarchive it with `PUT /api/ciphers/{id}/unarchive`, SHALL offer Archive on every active item and Unarchive on every archived item without a premium check, and SHALL show the server's message when the server refuses.

#### Scenario: Archiving an item
- **GIVEN** an active login
- **WHEN** the user chooses Archive
- **THEN** Prizm SHALL call `PUT /api/ciphers/{id}/archive`
- **AND** the login SHALL move from All Items to Archive
- **AND** VoiceOver SHALL announce "Item archived"

#### Scenario: No premium check
- **GIVEN** an active item in a read-only organization collection
- **WHEN** the user opens its context menu
- **THEN** Archive SHALL be offered, whatever the profile's `premium` value

#### Scenario: Item not found
- **GIVEN** the archive endpoint answers HTTP 404 with a server error message
- **WHEN** the user chooses Archive
- **THEN** the user SHALL see the server's message
- **AND** the item SHALL stay in its current lists

#### Scenario: Server without archive support
- **GIVEN** the archive endpoint answers HTTP 404 without a server error message
- **WHEN** the user chooses Archive
- **THEN** the user SHALL see "This server doesn't support archiving items."
- **AND** the item SHALL stay in its current lists

#### Scenario: Older server without archivedDate
- **GIVEN** a sync response from Vaultwarden 1.35.4, in which no cipher has an `archivedDate` key
- **WHEN** the vault is shown
- **THEN** every list SHALL contain the same items as before this change
- **AND** no Archive action or Archive sidebar entry SHALL be shown

#### Scenario: Empty vault
- **GIVEN** a sync response with no ciphers
- **WHEN** the user creates an item
- **THEN** Archive SHALL be offered for it
