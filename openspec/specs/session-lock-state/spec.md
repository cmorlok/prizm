# session-lock-state Specification

## Purpose
What a lock or sign-out does to work that is still running: sign-ins, two-factor steps, password
and Touch ID unlocks, Touch ID enrollment, syncs and on-demand decryption. A lock or sign-out ends
the session first; no older flow may load keys, install tokens, return decrypted data or change the
screen of the session that follows it.

## Requirements

### Requirement: A lock or sign-out ends every running flow
When the vault is locked or the user signs out while a sign-in, two-factor step, password unlock, Touch ID unlock or Touch ID enrollment is running, the system SHALL end that flow without loading its keys, giving its access token to the network layer, storing its enrollment or showing its screens. The lock SHALL take effect before any await of the lock itself, and no flow started before the lock's teardown has finished SHALL count as current.

#### Scenario: Lock during a Touch ID unlock
- **GIVEN** the unlock screen is shown with Touch ID armed
- **WHEN** the Mac goes to sleep before the Touch ID unlock ends
- **THEN** the lock screen SHALL be shown after wake with a newly armed Touch ID view, and no vault keys SHALL be loaded

#### Scenario: Sign-out during an unlock's token refresh
- **GIVEN** an unlock is refreshing the access token
- **WHEN** the user chooses "Sign Out…" from the menu and the refresh then returns
- **THEN** no access or refresh token of the signed-out account SHALL remain in the keychain or in the network layer

#### Scenario: Lock during an unlock's token refresh
- **GIVEN** an unlock is refreshing the access token
- **WHEN** the vault is locked and the refresh then returns
- **THEN** no vault keys SHALL be loaded and the network layer SHALL hold no access token, while the keychain SHALL keep the account's refreshed tokens

#### Scenario: Lock while the sign-in prepares the server
- **GIVEN** a sign-in is setting up the server environment
- **WHEN** the vault is locked before the password login starts
- **THEN** the sign-in SHALL load no keys, SHALL start no sync and SHALL show no vault

#### Scenario: Lock while the two-factor prompt is shown
- **GIVEN** the two-factor prompt is shown, or a code submission is in flight
- **WHEN** the vault is locked
- **THEN** the prompt SHALL close, no keys SHALL be loaded, and a code submission in flight SHALL not complete the sign-in

#### Scenario: Action on the old unlock screen during the lock's teardown
- **GIVEN** a lock has started and its teardown has not finished
- **WHEN** a Touch ID prompt re-arms or the user submits a password on the old unlock screen
- **THEN** that flow SHALL load no keys

### Requirement: An older flow never ends a newer session
A flow that started before a lock SHALL NOT load keys into, tear down, replace the unlock screen of, or change the screen of a session that started after that lock.

#### Scenario: Touch ID after a lock during a password unlock
- **GIVEN** a password unlock was running when the vault was locked, and the user then unlocks with Touch ID
- **WHEN** the password unlock ends
- **THEN** the Touch ID session SHALL stay unlocked

#### Scenario: Stale sign-in ends after a lock
- **GIVEN** a sign-in was running when the vault was locked, and the unlock screen is shown
- **WHEN** the sign-in ends
- **THEN** the unlock screen SHALL stay, SHALL show no error from the sign-in, and the login screen SHALL show no progress the next time it appears

### Requirement: Key caches and decrypting reads follow the lock
After a lock or sign-out started, a sync SHALL NOT write organization keys or item key sources into the key caches, and an on-demand decryption (password history, attachment download or conversion) SHALL NOT return decrypted data, even when it read its keys before the lock. Keys a refused write was given SHALL be zeroed.

#### Scenario: Lock between the sync's last check and the key cache write
- **GIVEN** a sync has passed its last lock check and is about to write the key caches
- **WHEN** the vault is locked at that point
- **THEN** the item key cache and the organization key cache SHALL be empty after the lock

#### Scenario: Lock while password history decrypts
- **GIVEN** the password history of an item is being read and its keys were copied before the lock
- **WHEN** the vault is locked before the read returns
- **THEN** the read SHALL return no entries

#### Scenario: Lock while an attachment downloads
- **GIVEN** an attachment is being downloaded or converted and its keys were copied before the lock
- **WHEN** the vault is locked before the decryption returns
- **THEN** no decrypted content SHALL be returned and no file SHALL remain in the temporary attachment folder

### Requirement: The lock screen shows only the lock state
After a lock, the unlock screen SHALL NOT show progress, prompts or sheets of a flow that started before the lock, and while an unlock runs, actions on the unlock screen that start a competing flow SHALL be disabled.

#### Scenario: Enrollment sheet open during a lock
- **GIVEN** the Touch ID enrollment sheet is shown after a password or Touch ID unlock
- **WHEN** the user presses Command-L or the Mac goes to sleep
- **THEN** the sheet SHALL close, nothing SHALL be enrolled, and the user SHALL be offered enrollment again after the next unlock

#### Scenario: No stale sync progress after a lock
- **GIVEN** an unlock is syncing and shows "Syncing…"
- **WHEN** the vault is locked
- **THEN** the unlock screen SHALL show no sync progress

#### Scenario: Competing actions during an unlock
- **GIVEN** a password or Touch ID unlock is running
- **WHEN** the unlock screen is shown
- **THEN** "Sign in with a different account" SHALL be disabled and the Touch ID badge SHALL be hidden

#### Scenario: Command-L on an idle unlock screen
- **GIVEN** the unlock screen is shown and nothing runs
- **WHEN** the user presses Command-L
- **THEN** nothing SHALL change, and a typed password SHALL stay in the field
