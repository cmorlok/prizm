## ADDED Requirements

### Requirement: Unit tests do not touch the developer's Touch ID preferences
Unit tests SHALL NOT read or write the Touch ID preferences (`biometricUnlockEnabled`,
`biometricEnrollmentPromptShown`) in the app's real preferences domain (`UserDefaults.standard`).
The types that store them SHALL take the `UserDefaults` store as a required initializer parameter,
the app SHALL pass one store to all of them, and their tests SHALL pass a private store that is
emptied before and after the test.

#### Scenario: A test's writes stay in its own store
- **GIVEN** an `AuthRepositoryImpl` built with a private store
- **WHEN** the test enables Touch ID unlock, disables it, and signs out
- **THEN** each value SHALL be written to the private store
- **AND** `biometricUnlockEnabled` and `biometricEnrollmentPromptShown` in `UserDefaults.standard` SHALL be unchanged

#### Scenario: A view model reads the injected store
- **GIVEN** a private store with `biometricUnlockEnabled` set to true
- **WHEN** a `BiometricUnlockToggleViewModel` or `UnlockViewModel` is built with that store
- **THEN** it SHALL read the value from that store, whatever `UserDefaults.standard` holds

#### Scenario: A unit-test run keeps the developer's settings
- **GIVEN** "Unlock with Touch ID" is on in the developer's Prizm and the enrollment offer was already shown
- **WHEN** the unit tests run on that Mac
- **THEN** the setting SHALL still be on afterwards, and the enrollment offer SHALL not reappear

### Requirement: The app as unit-test host starts signed out
When the app runs only as the host of the unit tests (no UI-test state), it SHALL use empty in-memory
keychains, so it neither reads the developer's stored login nor runs the unlock screen's Touch ID
path, which writes the Touch ID preferences.

#### Scenario: The unit-test host starts signed out
- **GIVEN** the developer has a stored Prizm login
- **WHEN** the app starts as the host of the unit tests
- **THEN** it SHALL have no stored account and SHALL show the login screen
