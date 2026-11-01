# Spec Delta

## MODIFIED Requirements

### Requirement: Metadata footer displays created and updated dates (MODIFIED)
The system SHALL display "Updated" and "Created" dates below the last card section, left-aligned, stacked vertically, using default field text style with secondary (gray) color. Dates SHALL use `dd.MM.yyyy` format. Labels and dates SHALL be column-aligned. For login items with a password revision date, a "Password updated" row SHALL appear above "Updated". When the item has password history, a "Password history: N" button SHALL appear below "Created".

#### Scenario: Dates render below cards
- **WHEN** an item detail is displayed
- **THEN** "Updated: dd.MM.yyyy" and "Created: dd.MM.yyyy" SHALL appear below the last card, left-aligned, in gray text

#### Scenario: Password updated date
- **GIVEN** a login whose password was changed on 03.10.2026
- **WHEN** the item detail is displayed
- **THEN** "Password updated: 03.10.2026" SHALL appear above "Updated"

#### Scenario: Password history button
- **GIVEN** a login with three password history entries
- **WHEN** the item detail is displayed
- **THEN** a "Password history: 3" button SHALL appear below "Created"
