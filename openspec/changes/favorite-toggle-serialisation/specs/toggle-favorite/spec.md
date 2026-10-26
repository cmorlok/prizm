## ADDED Requirements

### Requirement: Fast repeated toggles end in the state of the last click
When the user toggles an item's favorite state again before the previous change is saved, the system SHALL apply the toggles in order, so that the item ends in the state of the last click, in Prizm and on the server.

#### Scenario: Star and unstar quickly
- **GIVEN** an item that is not a favorite
- **WHEN** the user clicks the star twice before the first change is saved
- **THEN** the item SHALL end as not a favorite
- **AND** the server SHALL have received "favorite" and then "not favorite"

#### Scenario: A failed change
- **GIVEN** the first change fails
- **WHEN** the error is shown
- **THEN** no further change SHALL be sent for that item until the user clicks again

#### Scenario: A lock while a change is being saved
- **GIVEN** a favorite change for an item is still being saved
- **WHEN** the user locks and unlocks Prizm and clicks the star of that item again
- **THEN** the new change SHALL be sent only after the first one ended
- **AND** the item SHALL end in the state of the last click

