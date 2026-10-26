# Proposal

## Why

**Criticality:** P1 (High: the required UI journeys have never run)

The Constitution requires XCUITests for critical UI journeys. The repository seems to have them, but
only one of the 14 files in `Prizm/UITests/` is built and run:

- **13 files are in no Xcode target.** `13818b8` ("add XCUITests for all user stories",
  2026-03-17) added them, and no commit ever added them to the project. The `PrizmUITests` target
  only exists since `70389ad` (TOTP, #73, 2026-10-16) and contains only
  `VerificationCodeJourneyTests.swift`.
- **They could not run anyway.** They launch the app with test hooks that were never implemented:
  `--ui-testing`, `--inject-session`, `--inject-vault`, `--skip-sync`, `--reset-session`,
  `--inject-attachments`, `--mock-biometrics`, `--biometric-enabled`. No commit ever added any of
  them to the app; the only hook that exists is `--ui-test-vault` (`App/UITestFixtures.swift`,
  DEBUG only).
- **Added to the target as they are, they don't compile.** 12 errors in 3 files:
  `navigationSplitViews` does not exist in the XCUITest API, and a `throw XCTSkip` sits in a function
  that is not `throws`. All 61 accessibility identifiers they use do exist in the app.
- **Many assertions are vacuous.** Patterns such as `guard x.waitForExistence(…) else { return }`
  or `if x.exists { XCTAssert… }` pass without checking anything when the test data is missing.

So 78 journey tests (login, unlock, browsing, search, keyboard, create, edit, trash, attachments,
Touch ID, accessibility labels, password generator) are effectively missing. CI does not notice,
because the `Prizm` scheme skips UI tests and no workflow runs the `PrizmUITests` scheme.

## Origin of the current behaviour

| Issue | Origin | Evidence |
|---|---|---|
| Files not in a target | Accidental | Added in `13818b8` without project references; never referenced since |
| Missing test hooks | Wrong premise | The tests assume launch arguments that were never implemented in the app |
| Vacuous assertions | Accidental | Written against unknown test data, so every step is optional |

## What Changes

Staged. This change makes every journey that needs no server run and pass, and makes the rest
visible as skipped with a reason. A test backend is a separate decision for later.

- **All 13 files join the `PrizmUITests` target** and compile.
- **One test seam, extended.** `UITestFixtures` (DEBUG only, compiled out of Release) gets explicit
  launch states, and the tests use them instead of the never-implemented arguments:
  - `--ui-test-vault`: unlocked, with a seeded in-memory vault (exists today)
  - `--ui-test-locked`: the unlock screen for a fixture account
  - `--ui-test-signed-out`: the login screen
- **Test runs never touch the developer's real login.** In any `--ui-test-*` mode the app uses an
  in-memory keychain and an in-memory biometric keychain. Lock and sign-out in a test can't delete
  the developer's stored account.
- **Deterministic fixture data.** The seeded vault gains the items the journeys need: a second
  login and a favourite, a card, an identity, a secure note and an attachment entry. It keeps no
  SSH key, for the empty-state journey.
- **Real assertions.** Tests assert against the known fixture instead of returning early.
- **Visible skips.** Tests that need something this change does not provide are skipped with an
  explicit reason that names what they need:
  - saving to a server (create, edit, delete, restore, favourite, attachment upload, download and
    delete): follow-up change `ui-test-backend`
  - a real account (successful login and unlock): run only when `BW_TEST_SERVER_URL`,
    `BW_TEST_EMAIL` and `BW_TEST_PASSWORD` are set, otherwise skipped
  - simulated Touch ID: follow-up change `ui-test-biometrics`

## Capabilities

### New Capabilities
- `ui-test-journeys`: which UI journeys run, how the app is started for them, and how missing
  prerequisites are reported.

### Modified Capabilities
_None._

## Non-Goals

- A test backend or a Vaultwarden rig for saving journeys. Decided separately, once the rig from
  `fix-cipher-edit-data-loss` exists (follow-up `ui-test-backend`).
- Simulated Touch ID (follow-up `ui-test-biometrics`).
- Running UI tests in CI. GitHub's macOS runners need a GUI session and signing for the test
  runner; a separate decision for the maintainer.
- Isolating `UserDefaults`. Journeys that change preferences, such as the password generator
  options, write them to the developer's settings for the app (design.md, Risks).

## Dependencies

- **Hard:** `fix-app-signing-settings`. Signed test runs need the restored bundle identifier.

## Impact

- **Project:** `Prizm/Prizm.xcodeproj/project.pbxproj`, membership of the 13 files and the shared
  helper in `PrizmUITests`, and of `App/UITestKeychains.swift` in the app.
- **App (DEBUG only):** `App/UITestFixtures.swift` (launch states, fixture data),
  `App/UITestKeychains.swift` (in-memory keychains) and `App/AppContainer.swift` (chooses them in
  test mode). Release builds contain none of it.
- **Tests:** the 13 UI test files, plus a shared helper (`UITests/UITestSupport.swift`) for launch,
  skips and the way SwiftUI exposes the app to XCUITest. `testSignOutKeyboardShortcut` is removed:
  it sends ⌘⇧Q, which can log the developer out of macOS (design D7).
- **App bugs found:** the converted journeys found five app bugs. They are marked in the tests and
  fixed in separate changes (design.md, Findings).
- **Docs:** `DEVELOPMENT.md`, how to run the UI tests.
- **Unit tests:** launch-state parsing and the in-memory keychains.
- **Security review:** yes. The seam must stay out of Release builds and must not reach real
  credentials.

## Estimate

| Step | Scope | Estimate |
|---|---|---|
| 1 | Target membership, compile fixes | 0.25 d |
| 2 | Launch states and in-memory keychains, with unit tests | 0.5 d |
| 3 | Fixture data | 0.25 d |
| 4 | Convert the 13 files: launch states, real assertions, skips | 0.5–0.75 d |
| 5 | Runs on the Mac, security check of the Release build | 0.25 d |
| **Total** | | **1.75–2 d** |
