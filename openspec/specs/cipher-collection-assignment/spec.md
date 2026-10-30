# cipher-collection-assignment Specification

## Purpose
Which collections an organization item belongs to, and how Prizm changes that list: only the
assignments the user changes, never a read-only collection, never one the server holds that Prizm
did not show.

## Requirements

### Requirement: Org items are assigned with a multi-select of writable collections
For an item that belongs to an organization, the create and edit sheets SHALL show every collection of that organization that the user can write (not `readOnly`) as a checkbox, sorted by name, with the item's current assignments checked. Each checkbox SHALL have the collection name as its VoiceOver label.

#### Scenario: Item in two collections
- **GIVEN** an org item assigned to writable collections "A" and "B"
- **WHEN** the user opens the edit sheet
- **THEN** "A" and "B" SHALL be shown checked
- **AND** other writable collections of the organization SHALL be shown unchecked

#### Scenario: Add a second collection
- **GIVEN** an org item assigned to "A"
- **WHEN** the user also checks "C" and saves
- **THEN** the item SHALL be assigned to "A" and "C"

#### Scenario: Read-only collection not offered for new assignments
- **GIVEN** the user has read-only access to collection "R" and the item is not in "R"
- **WHEN** the user opens the edit sheet
- **THEN** "R" SHALL NOT be offered

### Requirement: Assignments the user cannot change are always kept
When saving an org item, the system SHALL keep every collection the item is assigned to that the user cannot write or that Prizm does not know. The collections request SHALL NOT contain a collection the last sync lists as read-only for the user; such assignments SHALL stay in the item's collection list in Prizm. Assignments to collections Prizm does not know SHALL be sent back unchanged. Read-only assignments SHALL be shown checked and disabled with the text "View only, can't be removed".

#### Scenario: Item in a read-only collection
- **GIVEN** an org item assigned to writable "A" and read-only "R"
- **WHEN** the user unchecks nothing, checks "C" and saves
- **THEN** the collections request SHALL contain "A" and "C" and SHALL NOT contain "R"
- **AND** the saved item SHALL be assigned to "A", "R" and "C"

#### Scenario: Unknown collection id
- **GIVEN** an org item whose collection list contains an id that is not in the synced collections
- **WHEN** the user changes another collection and saves
- **THEN** the collections request SHALL still contain that id

### Requirement: Other members' collection changes are kept
When saving an org item, the system SHALL apply only the user's collection change (collections checked and unchecked in the edit sheet) to the collections the item has in the record Prizm holds at save time.

#### Scenario: Collection added elsewhere while the sheet is open
- **GIVEN** the edit sheet of an org item in "A" is open
- **AND** a sync brings in collection "B", added by another member, with an unchanged revision
- **WHEN** the user changes only the item's name and saves
- **THEN** no collections request SHALL be sent
- **AND** the item SHALL stay in "A" and "B"

#### Scenario: Collection added elsewhere and one added here
- **GIVEN** the same item and sync
- **WHEN** the user checks "C" and saves
- **THEN** the collections request SHALL contain "A", "B" and "C"

### Requirement: An org item always has at least one collection
The system SHALL NOT allow saving an org item, on create or on edit, when its resulting collection list is empty. The sheets SHALL NOT offer a "None" collection option.

#### Scenario: Creating an org item without a collection
- **GIVEN** the create sheet for an org item with no collection checked
- **THEN** Save SHALL be disabled
- **AND** the hint "Choose at least one collection." SHALL be shown under the collections card

#### Scenario: Unchecking the last collection
- **GIVEN** an org item assigned only to writable "A"
- **WHEN** the user unchecks "A"
- **THEN** Save SHALL be disabled

### Requirement: The collections endpoint is called only when assignments change
After updating an org item, the system SHALL call `PUT /api/ciphers/{id}/collections_v2` only when the item's resulting collection list (the user's change applied to the record Prizm holds at save time) differs, as a set, from the collections of that record. When the call fails after the item itself was saved, the system SHALL keep the saved fields with the original collections in the local vault and SHALL show "Your changes were saved, but the collection change failed. Try again."

#### Scenario: Edit without collection change
- **GIVEN** an org item in collection "A"
- **WHEN** the user changes only the password and saves
- **THEN** exactly one request SHALL be sent: `PUT /api/ciphers/{id}`

#### Scenario: Collection change fails
- **GIVEN** an org item in collection "A"
- **WHEN** the user adds "C", saves, the cipher PUT succeeds and `collections_v2` fails
- **THEN** the edit sheet SHALL stay open with "C" still checked
- **AND** the message "Your changes were saved, but the collection change failed. Try again." SHALL be shown and announced to VoiceOver
- **AND** the item in the vault list SHALL show the new field values and collection "A" only

#### Scenario: User loses access through the change
- **GIVEN** the `collections_v2` response has `unavailable: true`
- **WHEN** the save completes
- **THEN** the item SHALL be removed from the local vault
- **AND** the user SHALL see "Saved. You no longer have access to this item."
- **AND** Save SHALL be disabled and the sheet SHALL offer a Close button

### Requirement: Collection changes keep working on servers without collections_v2
When `PUT /api/ciphers/{id}/collections_v2` answers HTTP 405, or HTTP 404 with an empty body, the system SHALL send the same collection list with `PUT /api/ciphers/{id}/collections` through a separate legacy adapter. It SHALL NOT fall back on a 404 that carries an error body, and SHALL NOT call the legacy endpoint when `collections_v2` answers.

#### Scenario: Official server before v2024.6.0
- **GIVEN** a server where `collections_v2` does not exist and answers 404 with an empty body
- **WHEN** the user adds collection "C" to an org item and saves
- **THEN** the system SHALL send `PUT /api/ciphers/{id}/collections` with the new list
- **AND** the item SHALL be assigned to "C"

#### Scenario: Current server
- **GIVEN** a server where `collections_v2` answers 200
- **WHEN** the user changes the collections of an org item
- **THEN** no request SHALL be sent to `PUT /api/ciphers/{id}/collections`

#### Scenario: Not found with an error body
- **GIVEN** `collections_v2` answers 404 with an error body
- **WHEN** the user saves a collection change
- **THEN** the legacy endpoint SHALL NOT be called
- **AND** the user SHALL see "Your changes were saved, but the collection change failed. Try again."
