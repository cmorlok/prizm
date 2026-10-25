# Spec Delta

## ADDED Requirements

### Requirement: Arrow keys move the selection after a click
After the user clicks a row in the sidebar or in the item list, the arrow keys SHALL move the selection within that list. This SHALL also hold when the clicked row was already selected.

#### Scenario: Sidebar
- **GIVEN** the user clicked "Login" in the sidebar
- **WHEN** the user presses the down arrow
- **THEN** "Card" SHALL be selected

#### Scenario: Item list
- **GIVEN** the user clicked the first item in the list
- **WHEN** the user presses the down arrow
- **THEN** the second item SHALL be selected and shown in the detail pane

#### Scenario: Returning to a list
- **GIVEN** the user clicked an item row after selecting a sidebar row
- **WHEN** the user clicks the selected sidebar row again and presses the down arrow
- **THEN** the next sidebar row SHALL be selected

### Requirement: Menu commands SHALL NOT use system-wide shortcuts
No menu command SHALL use a key combination that macOS reserves system-wide, such as ⌘⇧Q (Log Out) or ⌃⌘Q (Lock Screen). "Sign Out…" SHALL have no keyboard shortcut.

#### Scenario: Sign Out menu item
- **WHEN** the user opens the Prizm menu
- **THEN** "Sign Out…" SHALL show no keyboard shortcut
