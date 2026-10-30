## Purpose

Offer item creation from the content pane toolbar.

## Requirements

### Requirement: Content pane provides new item creation via toolbar button
The content column SHALL display a `+` button in the toolbar via `ToolbarItem(placement: .primaryAction)`. The button SHALL open a `Menu` listing the item types Prizm can create. Selecting a type opens the create sheet for that type. The button SHALL carry `AccessibilityID.Create.newItemButton`.

The `+` button SHALL be conditionally rendered (not merely hidden) when `Trash` is selected — it must be absent from the view tree so that the ⌘N keyboard shortcut is also disabled in Trash.

#### Scenario: Plus button opens type menu
- **WHEN** the user clicks [+] in the content toolbar
- **THEN** a menu appears listing Login, Card, Identity and Secure Note
- **AND** SSH Key SHALL NOT be listed until Prizm can generate or import SSH keys (`ssh-key-integrity`)

#### Scenario: ⌘N creates Login outside Trash
- **WHEN** the user presses ⌘N while a non-Trash category is selected
- **THEN** the create sheet opens for a new Login item

#### Scenario: Plus button absent in Trash
- **WHEN** the user selects "Trash" in the sidebar
- **THEN** no [+] button is present and ⌘N has no effect

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
