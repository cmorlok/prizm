# Spec Delta

## ADDED Requirements

### Requirement: Every UI test file is built and run
Every Swift file in `Prizm/UITests/` SHALL be a member of the `PrizmUITests` target, and running the `PrizmUITests` scheme SHALL execute the tests of every file.

#### Scenario: All journey files run
- **GIVEN** the `PrizmUITests` scheme
- **WHEN** a developer runs it with signing for their own team
- **THEN** the test report SHALL list test results for each of the 14 files in `Prizm/UITests/`

### Requirement: UI tests start the app through explicit test states
UI tests SHALL start the app only with the DEBUG-only launch states `--ui-test-vault`, `--ui-test-locked` or `--ui-test-signed-out`. These states SHALL be compiled out of Release builds.

#### Scenario: Unlocked seeded vault
- **GIVEN** the app is launched with `--ui-test-vault`
- **THEN** it SHALL show the vault browser with the fixture items, without contacting a server

#### Scenario: Locked fixture account
- **GIVEN** the app is launched with `--ui-test-locked`
- **THEN** it SHALL show the unlock screen for the fixture account `uitest@example.com`

#### Scenario: Signed out
- **GIVEN** the app is launched with `--ui-test-signed-out`
- **THEN** it SHALL show the login screen, even if an account is stored on the Mac

#### Scenario: Release build
- **WHEN** the app is built in the Release configuration
- **THEN** the binary SHALL NOT contain the `--ui-test-` launch arguments

### Requirement: UI test runs never touch the real keychain
While any `--ui-test-*` state is active, the app SHALL use in-memory keychain storage, and it SHALL NOT read, write or delete items in the user's keychain.

#### Scenario: Sign out during a UI test
- **GIVEN** a developer with a stored Prizm login on their Mac
- **WHEN** a UI test signs out or locks the vault
- **THEN** the developer's stored login SHALL still be there after the test run

### Requirement: Missing prerequisites are reported, not hidden
A UI test that needs a server, a real account or simulated Touch ID, which the test run does not provide, SHALL be reported as skipped, with a message naming the missing prerequisite. It SHALL NOT pass without checking anything.

#### Scenario: Saving journey without a test backend
- **GIVEN** no test backend is available
- **WHEN** the create-item journey reaches its save step
- **THEN** the test SHALL be skipped with "Needs a test backend for saving (follow-up change ui-test-backend)."

#### Scenario: Login with a real account
- **GIVEN** `BW_TEST_SERVER_URL`, `BW_TEST_EMAIL` and `BW_TEST_PASSWORD` are not set
- **WHEN** the successful-login journey runs
- **THEN** it SHALL be skipped with a message naming the three variables

#### Scenario: Fixture data is asserted
- **GIVEN** the app is launched with `--ui-test-vault`
- **WHEN** a journey looks for a fixture item, for example the first login
- **THEN** a missing item SHALL fail the test instead of ending it early as passed

### Requirement: Known app bugs are marked, not hidden
A UI test that finds an app bug outside this change's scope SHALL name the bug and the follow-up change that fixes it. A bug that crashes the app SHALL skip the test with that message. Any other bug SHALL be marked as an expected failure, so that the test reports it once the bug is fixed.

#### Scenario: Known bug is fixed
- **GIVEN** a check marked as an expected failure for a known app bug
- **WHEN** the follow-up change fixes the bug
- **THEN** the test SHALL fail with an unexpected pass until the marker is removed

### Requirement: UI tests send no system-wide shortcuts
A UI test SHALL NOT send key combinations that macOS handles system-wide, such as ⌘⇧Q (Log Out) or ⌃⌘Q (Lock Screen).

#### Scenario: Shortcut check before a run
- **WHEN** the UI test sources are searched for key events with Command and Shift and Q, or Control and Command and Q
- **THEN** no match SHALL be found
