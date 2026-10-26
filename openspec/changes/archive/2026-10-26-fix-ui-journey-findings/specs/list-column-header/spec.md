# Spec Delta

## ADDED Requirements

### Requirement: No item is created from Trash
While Trash is selected, the app SHALL NOT open a create sheet, whatever the trigger, and pressing ⌘N SHALL leave the app running with Trash selected.

#### Scenario: ⌘N in Trash
- **GIVEN** Trash is selected
- **WHEN** the user presses ⌘N
- **THEN** no create sheet SHALL open, the app SHALL keep running, and Trash SHALL stay selected

#### Scenario: Create request while Trash is selected
- **GIVEN** Trash is selected
- **WHEN** any code path requests a create sheet
- **THEN** the request SHALL be ignored
