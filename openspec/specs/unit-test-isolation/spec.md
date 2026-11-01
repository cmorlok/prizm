# unit-test-isolation Specification

## Purpose
Unit tests run inside the app on the developer's Mac, so they must not read or change the developer's real settings or stored login: the Touch ID preferences come from an injected store, each test uses its own, and the app as test host starts signed out with in-memory keychains.

## Requirements

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

### Requirement: Tests wait for asynchronous state they assert on
A unit test that asserts on state which the code under test changes asynchronously (from a
notification, a task or a callback) SHALL wait for that change with a deadline before it asserts or
acts on it, and SHALL fail with a message when the deadline passes.

#### Scenario: Icons turned off and on again
- **GIVEN** a favicon loader that has cached an icon
- **WHEN** the test turns website icons off, waits until the loader has reset, turns them on and asks for the icon
- **THEN** the icon SHALL be requested from the server again, in every run

### Requirement: URL stubs keep one test's requests out of the next
A URL stub shared by unit tests SHALL NOT record or answer as current a request that a finished test
caused, including a redirect target the URL loading system starts after that test has ended, and
SHALL end a redirected request with the redirect response only when the redirect was not followed.

#### Scenario: Redirect followed at the end of a test
- **GIVEN** a test whose icon request was redirected and followed
- **WHEN** the next test starts and the follow-up request reaches the stub only then
- **THEN** the stub SHALL answer it without recording it, and the next test SHALL see only its own requests

#### Scenario: Redirect followed within the test
- **GIVEN** a redirect that the session's policy follows
- **WHEN** the stub reports the redirect
- **THEN** the request SHALL end with the target's answer, never with the 302

### Requirement: Statistical tests repeat only the per-sample work
A unit test that draws many samples SHALL do set-up and validation (loading or filtering resources,
building lookup tables) once, before its sampling loop, so the whole unit-test run stays short and
the test host's main thread is never blocked for long.

#### Scenario: Passphrase uniformity test
- **WHEN** `testPassphraseWordPicks_areUniform` makes its 50,000 passphrases
- **THEN** the word list is validated once and each passphrase only picks words, and the test takes
  seconds, not minutes, in a Debug build
