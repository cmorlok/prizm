## MODIFIED Requirements

### Requirement: Edit and create sheets include a folder picker
The system SHALL display a "Folder" picker in both the item edit sheet and the item create sheet when folders exist, for personal and organization items alike (folders are personal; see `org-items-in-folders`). The picker SHALL list all folders sorted alphabetically by name, plus a "None" option at the top. For existing items, the picker SHALL pre-select the item's current folder (or "None" if unfoldered). For new items, the picker SHALL default to "None". The selected folder SHALL be included as `folderId` in the cipher payload when saving. When no folders exist, the folder picker SHALL NOT be displayed. For an organization item it SHALL appear below the collection picker.

#### Scenario: Folder picker shown in edit sheet for personal item
- **WHEN** the user opens the edit sheet for an existing personal item
- **THEN** a "Folder" picker SHALL be displayed listing "None" followed by all folders alphabetically

#### Scenario: Folder picker shown in create sheet for personal item
- **WHEN** the user opens the create sheet for a new personal item
- **THEN** a "Folder" picker SHALL be displayed with "None" pre-selected

#### Scenario: Folder picker shown for org items
- **GIVEN** folders exist and the user opens the edit or create sheet for an item belonging to an organization
- **WHEN** the sheet renders
- **THEN** a "Folder" picker SHALL be displayed below the collection picker

#### Scenario: Current folder pre-selected on edit
- **GIVEN** a personal item is assigned to folder "Work"
- **WHEN** the edit sheet opens
- **THEN** "Work" SHALL be pre-selected in the folder picker

#### Scenario: Folder selection included in save payload
- **GIVEN** the user selects folder "Personal" in the picker
- **WHEN** the user saves the item
- **THEN** the cipher payload SHALL include `folderId` set to the "Personal" folder's ID
