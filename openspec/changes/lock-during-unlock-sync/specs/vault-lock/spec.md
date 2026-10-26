## ADDED Requirements

### Requirement: A lock during a running sync stays in effect
When the vault is locked while the sync after unlocking or signing in is still running, the system SHALL keep showing the lock screen (or the login screen when no account is stored) when that sync ends, whether it succeeded or failed. The vault browser SHALL be shown only while the vault is unlocked.

#### Scenario: Lock while the unlock sync runs
- **GIVEN** the user unlocked the vault and the sync is running
- **WHEN** the user presses ⌘L and the sync then finishes
- **THEN** the lock screen SHALL stay visible
- **AND** no "Syncing…" screen from the interrupted sync SHALL replace it

#### Scenario: Lock while the sign-in sync runs
- **GIVEN** the user signed in and the first sync is running
- **WHEN** the Mac goes to sleep and the sync then finishes
- **THEN** the lock screen SHALL be shown, not the vault browser
