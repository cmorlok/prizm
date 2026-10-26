# Spec Delta

## ADDED Requirements

### Requirement: Locking and signing out drop decrypted vault browser state
When the vault locks (manually, on sleep, on screensaver or on screen lock) or the user signs out, the app SHALL drop the vault browser's selected item, listed items, folder, organization and collection names, and search term from memory. A vault read that was in flight when the vault locked SHALL NOT restore them.

#### Scenario: Lock with an item selected
- **GIVEN** the vault browser shows an item in the detail pane
- **WHEN** the vault locks
- **THEN** no item SHALL be selected and the item list SHALL be empty
- **AND** Item → Edit and the copy commands SHALL be disabled on the unlock screen

#### Scenario: Read in flight during the lock
- **GIVEN** an item list refresh has started and not finished
- **WHEN** the vault locks before the refresh delivers its result
- **THEN** the item list SHALL stay empty

#### Scenario: Save completing after the lock
- **GIVEN** an item save has started and not finished
- **WHEN** the vault locks before the save completes
- **THEN** the saved item SHALL NOT be selected and nothing SHALL be copyable on the unlock screen

#### Scenario: Save completing in the next session
- **GIVEN** an item save has started and the vault was locked and unlocked again before it completed
- **WHEN** the save completes
- **THEN** the saved item SHALL NOT be selected

#### Scenario: Sign out
- **GIVEN** the vault browser shows an item
- **WHEN** the user signs out
- **THEN** no item SHALL be selected and the item list SHALL be empty
