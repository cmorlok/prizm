# Spec Delta

## ADDED Requirements

### Requirement: Org items are never encrypted with the personal vault key
When the user creates or updates an item that has an `organizationId`, the system SHALL encrypt it with that organization's key. If that key is not available, the system SHALL NOT send any request, SHALL keep the sheet open with the user's input, and SHALL show "This item's organization can't be accessed right now. Lock and unlock Prizm, then try again."

#### Scenario: Update with the org key missing
- **GIVEN** an org item whose organization key is not in the key cache
- **WHEN** the user edits the item and saves
- **THEN** no request SHALL be sent to the server
- **AND** the error message SHALL be shown inline and announced to VoiceOver
- **AND** the edit sheet SHALL stay open with the user's changes

#### Scenario: Create with the org key missing
- **GIVEN** a new item draft for an organization whose key is not in the key cache
- **WHEN** the user saves
- **THEN** no create request SHALL be sent
- **AND** the error message SHALL be shown

#### Scenario: Personal item unaffected
- **GIVEN** a personal item and no organization keys at all
- **WHEN** the user edits and saves it
- **THEN** it SHALL be encrypted with the vault key and saved as today

### Requirement: Organization keys stay available while a sync runs
The system SHALL replace the cached organization keys in a single step after all keys of a sync have been unwrapped. A save that runs during a sync SHALL see either the previous keys or the new keys, never an empty set. If a sync fails before that step, the previous keys SHALL remain.

#### Scenario: Save during a sync
- **GIVEN** a sync is unwrapping organization keys
- **WHEN** the user saves an org item at the same moment
- **THEN** the item SHALL be encrypted with its organization key

#### Scenario: Sync fails after loading the profile
- **GIVEN** organization keys from an earlier sync are cached
- **WHEN** a new sync fails before its keys are swapped in
- **THEN** the earlier organization keys SHALL still be available for saving

#### Scenario: User left an organization
- **GIVEN** a successful sync no longer lists organization "O"
- **WHEN** the user tries to save an item of "O" that is still on screen
- **THEN** the save SHALL fail with the organization error and no request SHALL be sent
