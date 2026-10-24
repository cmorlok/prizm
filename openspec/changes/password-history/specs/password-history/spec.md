# Spec Delta

## ADDED Requirements

### Requirement: Changing a password records the old one in the item's history
When the user saves a login whose password changed or was cleared, compared with the server's stored record, from a non-empty value, the system SHALL add the old password with the save time to the front of the item's password history, encrypted with the item's effective key. Existing entries SHALL be sent back unchanged, byte for byte.

#### Scenario: Password change is recorded
- **GIVEN** a login with password "old-secret" and an empty history
- **WHEN** the user changes the password to "new-secret" and saves
- **THEN** the item's history SHALL contain one entry with value "old-secret" and the save date
- **AND** an official Bitwarden client SHALL show that entry in the item's password history

#### Scenario: First password adds nothing
- **GIVEN** a login without a password
- **WHEN** the user sets a password and saves
- **THEN** the history SHALL be unchanged and the password revision date SHALL be the save time

#### Scenario: Retry after a partly failed save
- **GIVEN** a save whose collection change failed after the password change was saved
- **WHEN** the user saves again
- **THEN** the history SHALL hold one entry for the old password, not two

#### Scenario: Unchanged password adds nothing
- **WHEN** the user edits only the item's name and saves
- **THEN** the history SHALL be unchanged

### Requirement: Hidden field changes are recorded and the history is capped
When a hidden custom field with a name and a value, on any item type, changes its value or is removed or renamed, the system SHALL add `"<name>: <old value>"` to the history, as official Bitwarden clients do. The history SHALL keep only the most recent entries, up to the same limit as official clients.

#### Scenario: Hidden field change is recorded
- **GIVEN** a login with a hidden custom field "PIN" whose value is "1234"
- **WHEN** the user changes the field value to "5678" and saves
- **THEN** the history SHALL gain an entry "PIN: 1234"

#### Scenario: Hidden field on a card
- **GIVEN** a card with a hidden custom field "PIN" whose value is "1234"
- **WHEN** the user removes the field and saves
- **THEN** the history SHALL gain an entry "PIN: 1234"

#### Scenario: History is capped
- **GIVEN** an item whose history already holds the maximum number of entries
- **WHEN** the user changes the password and saves
- **THEN** the new entry SHALL be first and the oldest entry SHALL be dropped

### Requirement: User can view and copy past passwords
The detail view SHALL show a "Password history: N" button when an item has N > 0 history entries. Activating it SHALL open a sheet that lists the entries by date, newest first, each with its date and a value masked by default, revealable with the eye toggle or by holding Option, and copyable with the same clipboard clearing as passwords. An entry that cannot be read SHALL be shown as such, without a value. Every control SHALL have a VoiceOver label.

#### Scenario: View history
- **GIVEN** an item with two history entries
- **WHEN** the user clicks "Password history: 2"
- **THEN** a sheet SHALL list both entries newest first with dates and masked values

#### Scenario: Copy a past password
- **WHEN** the user copies an entry in the sheet
- **THEN** the value SHALL be placed on the clipboard and cleared after the clipboard timeout

#### Scenario: Entry that cannot be read
- **GIVEN** an item with two history entries, one of which does not decrypt
- **WHEN** the user opens the history
- **THEN** the sheet SHALL show the readable entry and a row "Entry could not be read" without reveal or copy

#### Scenario: No history
- **GIVEN** an item without history
- **WHEN** the item detail is shown
- **THEN** no "Password history" button SHALL be shown

### Requirement: Past passwords are decrypted only while viewed
The system SHALL NOT decrypt password history entries during sync or item display. Entries SHALL be decrypted only when the history sheet opens and SHALL be cleared from memory when the sheet closes or the vault locks.

#### Scenario: Vault locks while the sheet is open
- **GIVEN** the password history sheet is open
- **WHEN** the vault locks
- **THEN** the sheet SHALL close and the decrypted entries SHALL be released
