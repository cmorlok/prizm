## Purpose

Lock the vault manually and automatically when the Mac sleeps or locks.

## Requirements

### Requirement: User can lock the vault manually with ⌘L
The system SHALL provide a **Lock Vault** command in the application menu with the keyboard shortcut ⌘L. The command SHALL be enabled only when the vault is unlocked (vault browser visible or sync in progress). Activating the command SHALL immediately zero all in-memory key material, clear the vault item cache, and transition to the unlock screen. If biometric unlock is enabled, the system SHALL automatically trigger the biometric prompt as soon as the unlock screen appears. The user SHALL always be able to unlock by entering their master password.

#### Scenario: Lock Vault command is available in the vault browser
- **WHEN** the vault browser is visible or a vault sync is in progress
- **THEN** the Lock Vault command in the application menu SHALL be enabled and show the ⌘L shortcut

#### Scenario: Lock Vault command is disabled outside the vault browser
- **WHEN** the login screen, unlock screen, or loading screen is visible
- **THEN** the Lock Vault command SHALL be disabled

#### Scenario: Manual lock transitions to the unlock screen
- **GIVEN** the vault browser is visible
- **WHEN** the user presses ⌘L or selects Lock Vault from the menu
- **THEN** the vault SHALL be locked immediately, all in-memory key material SHALL be zeroed, the vault item cache SHALL be cleared, and the unlock screen SHALL be shown

#### Scenario: Biometric prompt fires automatically after manual lock
- **GIVEN** biometric unlock is enabled AND the vault browser is visible
- **WHEN** the user locks the vault via ⌘L or the menu
- **THEN** the unlock screen SHALL appear AND the biometric prompt SHALL fire automatically without requiring any additional user interaction

#### Scenario: Vault can be unlocked after manual lock
- **GIVEN** the vault has been manually locked
- **WHEN** the user enters the correct master password on the unlock screen
- **THEN** the vault SHALL unlock and the vault browser SHALL be shown

---

### Requirement: Vault locks automatically when the Mac goes to sleep
The system SHALL observe the Mac sleep event and lock the vault automatically before the system sleeps. No user interaction is required. The lock SHALL fire whenever the vault is unlocked — including during an active vault sync — not only when the vault browser is fully loaded.

#### Scenario: Vault locks on Mac sleep
- **GIVEN** the vault browser is visible
- **WHEN** the Mac goes to sleep (lid close, sleep menu item, or inactivity sleep)
- **THEN** the vault SHALL be locked immediately, all in-memory key material SHALL be zeroed, the vault item cache SHALL be cleared, and the unlock screen SHALL be visible when the Mac wakes

#### Scenario: Sleep while vault is already locked is a no-op
- **GIVEN** the vault is not currently unlocked (unlock screen or login screen is shown)
- **WHEN** the Mac goes to sleep
- **THEN** no state change SHALL occur

---

### Requirement: Vault locks automatically when the screensaver starts
The system SHALL observe the screensaver start event and lock the vault automatically. The lock SHALL fire whenever the vault is unlocked — including during an active vault sync — not only when the vault browser is fully loaded.

#### Scenario: Vault locks when screensaver starts
- **GIVEN** the vault browser is visible
- **WHEN** the macOS screensaver activates
- **THEN** the vault SHALL be locked immediately, all in-memory key material SHALL be zeroed, the vault item cache SHALL be cleared, and the unlock screen SHALL be visible when the screensaver is dismissed

#### Scenario: Screensaver start while vault is already locked is a no-op
- **GIVEN** the vault is not currently unlocked (unlock screen or login screen is shown)
- **WHEN** the screensaver activates
- **THEN** no state change SHALL occur

---

### Requirement: Vault locks automatically when the screen is locked
The system SHALL observe the macOS screen lock event (⌃⌘Q or Lock Screen menu) and lock the vault automatically. The lock SHALL fire whenever the vault is unlocked — including during an active vault sync.

#### Scenario: Vault locks on screen lock
- **GIVEN** the vault browser is visible
- **WHEN** the user locks the screen via ⌃⌘Q or the Lock Screen menu item
- **THEN** the vault SHALL be locked immediately, all in-memory key material SHALL be zeroed, the vault item cache SHALL be cleared, and the unlock screen SHALL be visible when the screen is unlocked

#### Scenario: Screen lock while vault is already locked is a no-op
- **GIVEN** the vault is not currently unlocked (unlock screen or login screen is shown)
- **WHEN** the screen is locked
- **THEN** no state change SHALL occur

### Requirement: Locking and signing out drop decrypted vault browser state
When the vault locks (manually, on sleep, on screensaver or on screen lock) or the user signs out, the app SHALL drop the vault browser's selected item, listed items, folder, organization and collection names, and search term from memory. A vault read that was in flight when the vault locked SHALL NOT restore them.

#### Scenario: Lock with an item selected
- **GIVEN** the vault browser shows an item in the detail pane
- **WHEN** the vault locks
- **THEN** no item SHALL be selected and the item list SHALL be empty
- **AND** Item → Edit and the copy commands SHALL be disabled on the unlock screen

#### Scenario: Read in flight during the lock
- **GIVEN** an item list refresh has started and not finished
- **WHEN** the vault locks before the refresh delivers its result
- **THEN** the item list SHALL stay empty

#### Scenario: Save completing after the lock
- **GIVEN** an item save has started and not finished
- **WHEN** the vault locks before the save completes
- **THEN** the saved item SHALL NOT be selected and nothing SHALL be copyable on the unlock screen

#### Scenario: Save completing in the next session
- **GIVEN** an item save has started and the vault was locked and unlocked again before it completed
- **WHEN** the save completes
- **THEN** the saved item SHALL NOT be selected

#### Scenario: Sign out
- **GIVEN** the vault browser shows an item
- **WHEN** the user signs out
- **THEN** no item SHALL be selected and the item list SHALL be empty

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
