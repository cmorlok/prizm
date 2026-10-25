# Tasks

Estimates are ideal engineer-days. Write a failing test first (§IV): for the seam, unit tests;
for the journeys, the UI tests themselves.
**Prerequisite:** `fix-app-signing-settings` (signed test runs).

## 1. Target and compile (0.25 d)

- [ ] 1.1 Add the 13 files in `Prizm/UITests/` to the `PrizmUITests` target (file references, group, Sources phase). Record the compile errors in design.md, Context.
- [ ] 1.2 Fix the compile errors without changing what the tests check: replace `navigationSplitViews`, make tests that throw `XCTSkip` `throws`.

## 2. Seam (0.5 d)

- [ ] 2.1 Failing unit tests: `UITestFixtures.LaunchState` parses `--ui-test-vault`, `--ui-test-locked` and `--ui-test-signed-out`, and no argument means no test mode.
- [ ] 2.2 Failing unit tests: `InMemoryKeychainService` and `InMemoryBiometricKeychainService` store, read and delete like the protocol requires, and start empty unless pre-filled.
- [ ] 2.3 Implement design D1 and D2 inside `#if DEBUG`: launch states in `UITestFixtures`, in-memory keychains, and `AppContainer` and `RootViewModel` choosing them in test mode. `AppContainer.keychain` and `.biometricKeychain` become protocol-typed.
- [ ] 2.4 Fixture data per design D3. `VerificationCodeJourneyTests` still passes 9 of 9.

## 3. Journeys (0.5–0.75 d)

- [ ] 3.1 Shared helper `UITestPrerequisite` (design D5) in the UI test target.
- [ ] 3.2 Switch all 13 files to the launch states of D1.
- [ ] 3.3 Replace vacuous patterns with assertions against the fixture (D4).
- [ ] 3.4 Mark the server, real-account and Touch ID steps with `UITestPrerequisite` (D5). Partial journeys keep their local steps.

## 4. Verify (0.25 d)

- [ ] 4.1 Run the `PrizmUITests` scheme signed with a non-maintainer team: every test passes or is skipped with a D5 message; none fails. Record the counts (passed, skipped per reason).
- [ ] 4.2 Run the `PrizmUITests` scheme with a stored Prizm login on the Mac: the login is still there afterwards (D2).
- [ ] 4.3 Release build: `strings` on the binary finds no `--ui-test-` argument (D6).
- [ ] 4.4 Unit tests (`PrizmTests`) pass.
- [ ] 4.5 Security review: the seam is DEBUG-only and cannot reach the real keychain.
- [ ] 4.6 `DEVELOPMENT.md`: how to run the UI tests, that they drive the screen, the test states, and the `BW_TEST_*` variables. No CHANGELOG entry: nothing user-visible changes.
- [ ] 4.7 `openspec validate fix-ui-test-target --type change --strict`.
