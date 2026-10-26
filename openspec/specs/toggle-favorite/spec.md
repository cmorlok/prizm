## Purpose

Let the user mark items as favorites from the detail view and the item list.

## Requirements

### Requirement: User can toggle favorite from the detail view
The detail view toolbar SHALL display a star toggle button. When the item is not favorited, the button SHALL show an empty star (`star`). When favorited, it SHALL show a filled star (`star.fill`). Tapping the button SHALL toggle the favorite status, update the server, and refresh the item list and sidebar counts immediately.

#### Scenario: Favorite an unfavorited item from detail view
- **GIVEN** an unfavorited item is selected
- **WHEN** the user clicks the star button in the detail toolbar
- **THEN** the item SHALL be marked as favorite, the star SHALL become filled, the item SHALL appear in the Favorites sidebar, and the Favorites count SHALL increment

#### Scenario: Unfavorite a favorited item from detail view
- **GIVEN** a favorited item is selected
- **WHEN** the user clicks the filled star button in the detail toolbar
- **THEN** the item SHALL be unfavorited, the star SHALL become empty, and the Favorites count SHALL decrement

#### Scenario: Star button disabled for trashed items
- **GIVEN** a trashed item is selected
- **THEN** the star toggle button SHALL NOT be shown

---

### Requirement: User can toggle favorite from the item list context menu
The item list row context menu SHALL include a "Favorite" or "Unfavorite" option (label adapts to current state). Selecting it SHALL toggle the favorite status and sync to the server.

#### Scenario: Favorite via context menu
- **GIVEN** an unfavorited item in the list
- **WHEN** the user right-clicks and selects "Favorite"
- **THEN** the item SHALL be marked as favorite

#### Scenario: Unfavorite via context menu
- **GIVEN** a favorited item in the list
- **WHEN** the user right-clicks and selects "Unfavorite"
- **THEN** the item SHALL be unfavorited

---

### Requirement: Remove star indicator from item list rows (REMOVED)
The item list rows SHALL NOT display the yellow star icon for favorited items. The favorite status is indicated by the item's presence in the Favorites sidebar category and by the star toggle in the detail view toolbar.

#### Scenario: No star icon in list rows
- **WHEN** a favorited item is displayed in the item list
- **THEN** no star icon SHALL appear next to the item name

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
