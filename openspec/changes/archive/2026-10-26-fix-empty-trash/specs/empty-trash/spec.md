# Spec Delta

## ADDED Requirements

### Requirement: Empty Trash deletes exactly the trashed items
The system SHALL provide an "Empty Trash" action in the Trash view. It SHALL permanently delete the items that are in Trash by sending their ids with `DELETE /api/ciphers` and body `{"ids": [...]}`, in requests of at most 500 ids. It SHALL NOT delete any item that is not in Trash.

#### Scenario: Empty a trash with three items
- **GIVEN** three items are in Trash and ten items are active
- **WHEN** the user chooses Empty Trash and confirms
- **THEN** one `DELETE /api/ciphers` request SHALL be sent with exactly the three trashed ids
- **AND** the ten active items SHALL remain in the vault

#### Scenario: Large trash
- **GIVEN** 1,200 items are in Trash
- **WHEN** the user empties the trash
- **THEN** three requests SHALL be sent with 500, 500 and 200 ids

#### Scenario: Button state
- **GIVEN** the Trash view is shown
- **THEN** the "Empty Trash" button SHALL be disabled when Trash is empty and enabled otherwise

### Requirement: The purge endpoint is never called
The system SHALL NOT send any request to a path ending in `/ciphers/purge`, with any HTTP method.

#### Scenario: Guard test
- **GIVEN** the full unit test suite runs with the recording mock URL protocol
- **WHEN** any test triggers an API request
- **THEN** no recorded request path SHALL end in `/purge`

### Requirement: Empty Trash works on current data and confirms the count
Before asking for confirmation, the system SHALL sync, compute the trashed items from the fresh data, and show "Permanently delete N items?" with the message "This can't be undone." If the sync fails, the system SHALL NOT delete anything and SHALL show "Couldn't refresh the trash. Try again."

#### Scenario: Item restored on another device
- **GIVEN** Prizm's last sync shows items X and Y in Trash, and X was restored on another device since
- **WHEN** the user chooses Empty Trash
- **THEN** the confirmation SHALL say "Permanently delete 1 item?"
- **AND** only Y SHALL be deleted

#### Scenario: Sync fails
- **GIVEN** the server cannot be reached
- **WHEN** the user chooses Empty Trash
- **THEN** no delete request SHALL be sent
- **AND** the message "Couldn't refresh the trash. Try again." SHALL be shown

### Requirement: The outcome is reported, including partial failure
After deleting, the system SHALL sync again. It SHALL announce "N items permanently deleted" to VoiceOver when at least one item was deleted. If items remain in Trash, it SHALL show "N items could not be deleted. You may not have permission to delete them.", or "N items could not be deleted. Check your connection and try again." when the server could not be reached.

#### Scenario: One item may not be deleted
- **GIVEN** Trash holds two personal items and one org item the user may not delete
- **WHEN** the user empties the trash
- **THEN** after the follow-up sync the Trash view SHALL list only the org item
- **AND** the user SHALL see "1 item could not be deleted. You may not have permission to delete them."

#### Scenario: Server not reachable
- **GIVEN** Trash holds one item
- **WHEN** the user empties the trash and the server cannot be reached
- **THEN** the user SHALL see "1 item could not be deleted. Check your connection and try again."
- **AND** nothing SHALL be announced as deleted
