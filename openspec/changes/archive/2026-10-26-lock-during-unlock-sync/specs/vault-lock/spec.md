## ADDED Requirements

### Requirement: A lock during a running sync stays in effect
When the vault is locked while an unlock or sign-in is still deriving keys or running its first sync, the system SHALL keep showing the lock screen (or the login screen when no account is stored) when that flow ends, whether it succeeded or failed, and SHALL discard any keys it loaded after the lock. A two-factor prompt from a sign-in that started before the lock SHALL NOT be shown. The vault browser SHALL be shown only while the vault is unlocked.

#### Scenario: Lock while the unlock sync runs
- **GIVEN** the user unlocked the vault and the sync is running
- **WHEN** the user presses ⌘L and the sync then finishes
- **THEN** the lock screen SHALL stay visible
- **AND** no "Syncing…" screen from the interrupted sync SHALL replace it

#### Scenario: Lock while the sign-in sync runs
- **GIVEN** the user signed in and the first sync is running
- **WHEN** the Mac goes to sleep and the sync then finishes
- **THEN** the lock screen SHALL be shown, not the vault browser

#### Scenario: Lock while an unlock derives keys
- **GIVEN** the user entered the master password and the unlock is deriving keys
- **WHEN** the Mac goes to sleep and the unlock then finishes
- **THEN** the lock screen SHALL stay visible, with no "Syncing…" screen
- **AND** the keys the unlock loaded SHALL be discarded

## MODIFIED Requirements

### Requirement: User can lock the vault manually with ⌘L
The system SHALL provide a **Lock Vault** command in the application menu with the keyboard shortcut ⌘L. The command SHALL be enabled when the vault is unlocked (vault browser visible or sync in progress) and while a sign-in or password unlock is in progress (deriving keys or running its first sync). Activating the command SHALL immediately zero all in-memory key material, clear the vault item cache, and transition to the unlock screen. If biometric unlock is enabled, the system SHALL automatically trigger the biometric prompt as soon as the unlock screen appears. The user SHALL always be able to unlock by entering their master password.

#### Scenario: Lock Vault command is available in the vault browser
- **WHEN** the vault browser is visible or a vault sync is in progress
- **THEN** the Lock Vault command in the application menu SHALL be enabled and show the ⌘L shortcut

#### Scenario: Lock Vault command is disabled outside the vault browser
- **WHEN** the login screen or unlock screen is visible and no sign-in or password unlock is in progress
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

### Requirement: Vault locks automatically when the Mac goes to sleep
The system SHALL observe the Mac sleep event and lock the vault automatically before the system sleeps. No user interaction is required. The lock SHALL fire whenever the vault is unlocked — including during an active vault sync — not only when the vault browser is fully loaded, and while a sign-in or password unlock is in progress.

#### Scenario: Vault locks on Mac sleep
- **GIVEN** the vault browser is visible
- **WHEN** the Mac goes to sleep (lid close, sleep menu item, or inactivity sleep)
- **THEN** the vault SHALL be locked immediately, all in-memory key material SHALL be zeroed, the vault item cache SHALL be cleared, and the unlock screen SHALL be visible when the Mac wakes

#### Scenario: Sleep while vault is already locked is a no-op
- **GIVEN** the vault is not currently unlocked (unlock screen or login screen is shown) and no sign-in or password unlock is in progress
- **WHEN** the Mac goes to sleep
- **THEN** no state change SHALL occur

### Requirement: Vault locks automatically when the screensaver starts
The system SHALL observe the screensaver start event and lock the vault automatically. The lock SHALL fire whenever the vault is unlocked — including during an active vault sync — not only when the vault browser is fully loaded, and while a sign-in or password unlock is in progress.

#### Scenario: Vault locks when screensaver starts
- **GIVEN** the vault browser is visible
- **WHEN** the macOS screensaver activates
- **THEN** the vault SHALL be locked immediately, all in-memory key material SHALL be zeroed, the vault item cache SHALL be cleared, and the unlock screen SHALL be visible when the screensaver is dismissed

#### Scenario: Screensaver start while vault is already locked is a no-op
- **GIVEN** the vault is not currently unlocked (unlock screen or login screen is shown) and no sign-in or password unlock is in progress
- **WHEN** the screensaver activates
- **THEN** no state change SHALL occur

### Requirement: Vault locks automatically when the screen is locked
The system SHALL observe the macOS screen lock event (⌃⌘Q or Lock Screen menu) and lock the vault automatically. The lock SHALL fire whenever the vault is unlocked — including during an active vault sync — and while a sign-in or password unlock is in progress.

#### Scenario: Vault locks on screen lock
- **GIVEN** the vault browser is visible
- **WHEN** the user locks the screen via ⌃⌘Q or the Lock Screen menu item
- **THEN** the vault SHALL be locked immediately, all in-memory key material SHALL be zeroed, the vault item cache SHALL be cleared, and the unlock screen SHALL be visible when the screen is unlocked

#### Scenario: Screen lock while vault is already locked is a no-op
- **GIVEN** the vault is not currently unlocked (unlock screen or login screen is shown) and no sign-in or password unlock is in progress
- **WHEN** the screen is locked
- **THEN** no state change SHALL occur
