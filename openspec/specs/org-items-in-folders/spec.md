# org-items-in-folders Specification

## Purpose
Show and file organization items in the user's personal folders.

## Requirements

### Requirement: Folder lists include organization items
The system SHALL list every active item whose per-user `folderId` matches a folder under that folder, whether the item is personal or belongs to an organization, and SHALL count it in that folder's count.

#### Scenario: Org item filed in another client
- **GIVEN** the user filed an organization login into their folder "Work" in the Bitwarden browser extension
- **WHEN** Prizm syncs and the user selects "Work"
- **THEN** the organization login SHALL be listed
- **AND** it SHALL still show its organization

### Requirement: Organization items can be filed into folders
The system SHALL offer the folder picker in the edit sheet for organization items as well as personal items, SHALL accept organization items dropped onto a folder, and SHALL keep the item's organization and collections when its folder changes.

#### Scenario: Choosing a folder for an org item
- **GIVEN** an organization item in collection "Shared"
- **WHEN** the user picks folder "Work" in the edit sheet and saves
- **THEN** the update SHALL set `folderId` to "Work"'s ID
- **AND** the item SHALL keep its `organizationId` and its collection "Shared"

#### Scenario: Deleting a folder that holds an org item
- **GIVEN** an organization item in folder "Work"
- **WHEN** the user deletes "Work"
- **THEN** the item SHALL have no folder
- **AND** the item SHALL keep its organization and collections
