## Purpose

Choose folder and collection when creating or editing an item.

## Requirements

### Requirement: Edit and create sheets include a folder picker
The system SHALL display a "Folder" picker in both the item edit sheet and the item create sheet when folders exist, for personal and organization items alike (folders are personal; see `org-items-in-folders`). The picker SHALL list all folders sorted alphabetically by name, plus a "None" option at the top. For existing items, the picker SHALL pre-select the item's current folder (or "None" if unfoldered). For new items, the picker SHALL default to "None". The selected folder SHALL be included as `folderId` in the cipher payload when saving. When no folders exist, the folder picker SHALL NOT be displayed. For an organization item it SHALL appear below the Collections card.

#### Scenario: Folder picker shown in edit sheet for personal item
- **WHEN** the user opens the edit sheet for an existing personal item
- **THEN** a "Folder" picker SHALL be displayed listing "None" followed by all folders alphabetically

#### Scenario: Folder picker shown in create sheet for personal item
- **WHEN** the user opens the create sheet for a new personal item
- **THEN** a "Folder" picker SHALL be displayed with "None" pre-selected

#### Scenario: Folder picker shown for org items
- **GIVEN** folders exist and the user opens the edit or create sheet for an item belonging to an organization
- **WHEN** the sheet renders
- **THEN** a "Folder" picker SHALL be displayed below the Collections card

#### Scenario: Current folder pre-selected on edit
- **GIVEN** a personal item is assigned to folder "Work"
- **WHEN** the edit sheet opens
- **THEN** "Work" SHALL be pre-selected in the folder picker

#### Scenario: Folder selection included in save payload
- **GIVEN** the user selects folder "Personal" in the picker
- **WHEN** the user saves the item
- **THEN** the cipher payload SHALL include `folderId` set to the "Personal" folder's ID

---

### Requirement: Create and edit sheets include an org collection picker for org items
The system SHALL display a "Collections" card in the item edit sheet and the item create sheet when the item belongs to an organization, with one checkbox per collection as defined in `cipher-collection-assignment`. In the create sheet, when the sidebar context is `.collection(id)` and the user can write that collection, it SHALL be pre-checked (passed via `selectedCollectionId` from `VaultBrowserViewModel`); a collection the user can only view SHALL NOT be pre-checked. The checked collections SHALL be included in `collectionIds[]` in the cipher payload when creating an item.

#### Scenario: Collections card shown in edit sheet for org item
- **WHEN** the user opens the edit sheet for an org item
- **THEN** a "Collections" card SHALL be displayed with a checkbox for each collection of the item's organization that the user can write

#### Scenario: Collection pre-selected when creating from collection context
- **GIVEN** the user clicked `+` with `.collection("col1")` active in the sidebar
- **AND** the user can write "col1"
- **WHEN** the create sheet opens
- **THEN** the org and collection "col1" SHALL be pre-selected

#### Scenario: Checked collections included in the create payload
- **GIVEN** the user checks collection "Infrastructure" in the create sheet
- **WHEN** the user saves
- **THEN** the cipher payload SHALL include `collectionIds = ["<infrastructure-id>"]`

#### Scenario: Org items route to POST /ciphers/create
- **GIVEN** the user saves a new item with a non-nil organizationId
- **WHEN** the create use case executes
- **THEN** `POST /api/ciphers/create` SHALL be called (not `POST /api/ciphers`)
