## MODIFIED Requirements

### Requirement: Settings window opens via ⌘, and gear toolbar button
The system SHALL provide a macOS Settings window using the SwiftUI `Settings` scene, accessible via ⌘, (standard macOS keyboard shortcut) and via a gear icon button in the sidebar toolbar of the vault browser, placed next to the sidebar toggle and visible without the toolbar overflow menu. The Settings window SHALL open as a separate native macOS window.

#### Scenario: Settings opens via keyboard shortcut
- **WHEN** the user presses ⌘, while the vault browser is visible
- **THEN** the Settings window SHALL open

#### Scenario: Settings opens via toolbar button
- **GIVEN** the vault browser is visible
- **WHEN** the user clicks the gear icon button in the toolbar
- **THEN** the Settings window SHALL open

#### Scenario: Gear button is visible in the vault browser toolbar
- **GIVEN** the vault is unlocked and the vault browser is shown
- **WHEN** the sidebar column is at its minimum width
- **THEN** a gear icon button SHALL be visible in the toolbar next to the sidebar toggle
- **AND** it SHALL NOT be moved into the "more toolbar items" overflow menu
