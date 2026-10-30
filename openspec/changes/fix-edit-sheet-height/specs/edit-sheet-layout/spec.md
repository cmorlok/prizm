## ADDED Requirements

### Requirement: The edit sheet leaves room for the item's fields
The edit and create sheet SHALL ask for an ideal height of 800 pt, so that the scrolling form under the fixed header (name, collections, folder) shows several fields. In a window too small for that height the sheet SHALL fit the window and its form SHALL scroll.

#### Scenario: Organization item in a tall window
- **GIVEN** a window 1170 pt tall and an organization item with collections and folders
- **WHEN** the user opens its edit sheet
- **THEN** the form below the collections and folder cards SHALL be at least 300 pt tall

#### Scenario: Small window
- **GIVEN** a window about 862 pt tall
- **WHEN** the user opens the edit sheet of an organization item
- **THEN** the sheet SHALL fit inside the window
- **AND** the user SHALL be able to scroll to the Notes field and reach Save
