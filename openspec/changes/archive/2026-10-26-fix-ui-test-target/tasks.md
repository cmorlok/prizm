# Tasks

Estimates are ideal engineer-days. Write a failing test first (§IV): for the seam, unit tests;
for the journeys, the UI tests themselves.
**Prerequisite:** `fix-app-signing-settings` (signed test runs).

## 1. Target and compile (0.25 d)

- [x] 1.1 Add the 13 files in `Prizm/UITests/` to the `PrizmUITests` target (file references, group, Sources phase). Record the compile errors in design.md, Context.
- [x] 1.2 Fix the compile errors without changing what the tests check: replace `navigationSplitViews`, make tests that throw `XCTSkip` `throws`.

## 2. Seam (0.5 d)

- [x] 2.1 Failing unit tests: `UITestFixtures.LaunchState` parses `--ui-test-vault`, `--ui-test-locked` and `--ui-test-signed-out`, and no argument means no test mode.
- [x] 2.2 Failing unit tests: `InMemoryKeychainService` and `InMemoryBiometricKeychainService` store, read and delete like the protocol requires, and start empty unless pre-filled.
- [x] 2.3 Implement design D1 and D2 inside `#if DEBUG`: launch states in `UITestFixtures`, in-memory keychains, and `AppContainer` choosing them in test mode (`RootViewModel` needs no change, see D1). `AppContainer.keychain` and `.biometricKeychain` become protocol-typed.
- [x] 2.4 Fixture data per design D3. `VerificationCodeJourneyTests` still passes 9 of 9.

## 3. Journeys (0.5–0.75 d)

- [x] 3.1 Shared helper `UITestPrerequisite` (design D5) in the UI test target.
- [x] 3.2 Switch all 13 files to the launch states of D1.
- [x] 3.3 Replace vacuous patterns with assertions against the fixture (D4).
- [x] 3.5 No UI test sends a system-wide shortcut (⌘⇧Q, ⌃⌘Q); `testSignOutKeyboardShortcut` is removed (design D7). Check with `grep` before every run.
- [x] 3.4 Mark the server, real-account and Touch ID steps with `UITestPrerequisite` (D5). Partial journeys keep their local steps.
- [x] 3.6 Shared query helpers for how SwiftUI exposes the app (design D8); app bugs the journeys find are marked per D5 and listed in design.md, Findings.

## 4. Verify (0.25 d)

- [x] 4.1 Run the `PrizmUITests` scheme signed with a non-maintainer team: every test passes or is skipped with a D5 message; none fails. Record the counts (passed, skipped per reason).
- [x] 4.2 Run the `PrizmUITests` scheme with a stored Prizm login on the Mac: the login is still there afterwards (D2).
  Checked by hand 2026-10-29 with a throwaway account (a fixture account on the Vaultwarden rig, signed in and unlocked in the normal app before the run). Full suite on a build of the fork's `develop`: 97 executed, 75 passed, 21 skipped, 1 failed (`AccessibilityLabelTests.testSettingsGearHasLabel`, the known failure of a large window). Afterwards the normal app was closed; relaunched, it was locked, not signed out, and unlocked with the master password.
- [x] 4.3 Release build: `strings` on the binary finds no `--ui-test-` argument (D6).
- [x] 4.4 Unit tests (`PrizmTests`) pass.
- [x] 4.5 Security review: the seam is DEBUG-only and cannot reach the real keychain.
- [x] 4.6 `DEVELOPMENT.md`: how to run the UI tests, that they drive the screen, the test states, and the `BW_TEST_*` variables. No CHANGELOG entry: nothing user-visible changes.
- [x] 4.7 `openspec validate fix-ui-test-target --type change --strict`.

## Results (2026-10-25, macOS 26, signed with a contributor team)

- 4.1 `PrizmUITests`: 86 tests, 64 passed, 22 skipped, 0 failed. Skips: 8 simulated Touch ID,
  7 test backend for saving, 1 test backend for downloads, 5 real account (4 with `BW_TEST_*`,
  1 with `BW_TEST_2FA_*`), 1 known app bug (⌘N in Trash crashes the app). Five passed tests record
  an expected failure for a known app bug (design.md, Findings).
- 4.3 Release binary: no `--ui-test-`, no fixture account, no `InMemoryKeychain` symbol. Control:
  the Debug build contains the arguments.
- 4.4 `PrizmTests`: 550 passed, including the 10 new seam tests.
- 4.5 Both seam files are `#if DEBUG` as a whole. `KeychainServiceImpl` and
  `BiometricKeychainServiceImpl` are the only code calling `SecItem*`, and only `AppContainer`
  creates them, on the non-test path. The biometric preferences are isolated for reads (design.md,
  Risks).
- 4.2 open: needs a run on a Mac with a stored Prizm login for the same bundle identifier.

## Verification (2026-10-26, `/opsx:verify`)

- No code gaps. Fixed: header comments in five UI test files named launch arguments that never
  existed (`--inject-session`, `--mock-biometrics`, …); a skip message named a test that does not
  exist and no prerequisite (`LoginJourneyTests`); the fixture keychain writes no longer ignore
  errors with `try?`.
- Open by design: 4.2 (hand check with a stored Prizm login).

