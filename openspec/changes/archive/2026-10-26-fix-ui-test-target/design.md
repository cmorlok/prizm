# Design

## Context

**Inventory (2026-10-25).**

| File | Tests | Launch arguments used | Needs |
|---|---|---|---|
| `VaultBrowserJourneyTests` | 11 | `--ui-testing --inject-session --inject-vault --skip-sync` | seeded vault; ⌘L needs a lockable account |
| `SearchJourneyTests` | 6 | same | seeded vault |
| `KeyboardNavigationTests` | 8 | same | seeded vault; one test signs out |
| `AccessibilityLabelTests` | 4 | same | seeded vault; favourite toggle saves |
| `PasswordGeneratorJourneyTests` | 2 | same | edit sheet; applying is local, saving is not |
| `CreateItemJourneyTests` | 8 | same | sheets open locally; saving needs a server |
| `EditItemJourneyTests` | 9 | same | sheets open locally; saving needs a server |
| `TrashJourneyTests` | 3 | same | delete, restore and purge need a server |
| `AttachmentJourneyTests` | 6 | same plus `--inject-attachments` | display is local; open and delete need a server |
| `LoginJourneyTests` | 7 | `--ui-testing --reset-session` | login screen; success needs a real account |
| `UnlockJourneyTests` | 7 | `--ui-testing --inject-session` | unlock screen; success needs a real account |
| `BiometricUnlockJourneyTests` | 4 | `--mock-biometrics …` | simulated Touch ID |
| `BiometricEnrollmentJourneyTests` | 3 | `--mock-biometrics …` | simulated Touch ID |
| `VerificationCodeJourneyTests` (in target) | 9 | `--ui-test-vault` | seeded vault; passes today |

- **Launch arguments.** No app source in the history ever contained `inject-session` or the other
  arguments the 13 files use (`git log -S` over all paths except `**/UITests/**`). The app knows
  `--ui-test-vault`, `--ui-test-open-codes` and `--ui-test-no-codes` (`App/UITestFixtures.swift`),
  read in `RootViewModel.init` (`App/PrizmApp.swift:296-316`) inside `#if DEBUG`.
- **Compile errors** with the 13 files added (Xcode, 2026-10-25): `navigationSplitViews` is not an
  `XCUIApplication` member (`BiometricEnrollmentJourneyTests.swift:58,72`,
  `BiometricUnlockJourneyTests.swift:47`); `throw XCTSkip` in a non-throwing test
  (`SearchJourneyTests.swift:54`, same pattern in `VaultBrowserJourneyTests`).
- **Identifiers.** All 61 identifiers the tests use exist in the app; `masked.<label>.value` and
  `.toggle` are built in `Presentation/AccessibilityIdentifiers.swift:116-117`.
- **Keychain.** `AuthRepositoryImpl` takes `any KeychainService` and `any BiometricKeychainService`
  (`Data/Repositories/AuthRepositoryImpl.swift:54-63`); `AppContainer` creates the real
  implementations (`App/AppContainer.swift:73-74`). Sign-out deletes the stored account and the
  biometric item (`AuthRepositoryImpl.swift:384-430`).
- **Schemes.** The `Prizm` scheme skips the UI test target, so `xcodebuild test -scheme Prizm` and
  CI never run UI tests. The `PrizmUITests` scheme runs them (`scripts/host/xcode.sh test-ui`).

## Goals / Non-Goals

**Goals**
- Every UI journey that needs no server runs and passes on a developer's Mac, signed with their
  own team.
- Every other journey is reported as skipped with the reason and the follow-up that enables it.
  Nothing is silently missing.
- A UI test run cannot read, change or delete the developer's real keychain items.
- The seam is not in Release builds.

**Non-Goals:** see proposal.md.

## Decisions

### D1. One seam with explicit launch states

`UITestFixtures` gets a `LaunchState` read from the arguments:

| Argument | State at launch |
|---|---|
| `--ui-test-vault` (exists) | Unlocked vault with the fixture items, no server |
| `--ui-test-locked` | Unlock screen for the fixture account (`uitest@example.com`) |
| `--ui-test-signed-out` | Login screen, with an empty in-memory keychain |

If several arguments are given, the most restrictive state wins (signed out, then locked, then
vault). The 13 files switch to these arguments through `UITestLaunch` in the UI test target.

`RootViewModel` needs no change: it already shows the seeded vault for `--ui-test-vault`, and for
the other two states the app's normal start-up decides from the keychain contents (D2). A
pre-filled in-memory keychain gives the unlock screen, an empty one the login screen.

**Rejected:** implementing the old arguments as named. `--inject-session` and `--reset-session`
suggest injecting into or resetting the real stored session, which is exactly what a test must
not do on a developer's Mac.

### D2. In-memory keychains in test mode

In any `--ui-test-*` mode, `AppContainer` passes an `InMemoryKeychainService` and an
`InMemoryBiometricKeychainService` (DEBUG only) to `AuthRepositoryImpl`. For `--ui-test-locked`,
the in-memory keychain is pre-filled with the fixture account's non-secret entries (email, server
URL), so the unlock screen and the ⌘L lock journey show the fixture account.

So lock and sign-out in tests act on the in-memory store, and the developer's stored login is
never read or deleted.

The unlock screen reads and writes `biometricUnlockEnabled` and `biometricEnrollmentPromptShown`
in `UserDefaults.standard`. With an in-memory keychain there is never a biometric item, and the
Touch ID path would clear the developer's real setting. In test mode, `AppContainer` therefore sets
both keys in the volatile argument domain (Touch ID off, enrollment already offered), which takes
precedence for reads and is never written to disk. See Risks for what this does not cover.

`AppContainer`'s stored properties `keychain` and `biometricKeychain` change from the concrete
classes to `any KeychainService` and `any BiometricKeychainService`. Nothing outside the
initializer uses their concrete type.

### D3. Deterministic fixture data

The seeded vault keeps the five existing logins (`VerificationCodeJourneyTests` depends on them)
and adds:
- `kappa` "Kappa Login": a login without TOTP, marked favourite
- `card1` "Test Card", `ident1` "Test Identity", `note1` "Test Note"
- one attachment entry (metadata only) on `kappa`

No SSH key, so the SSH Key category stays empty for the empty-state journey. New items have no TOTP
seed, so the Codes list is unchanged.

### D4. Real assertions against the fixture

Steps that may legitimately vary stay conditional. Everything the fixture guarantees is asserted.
Patterns such as `guard row.waitForExistence(…) else { return }` become
`XCTAssertTrue(row.waitForExistence(…), "…")`.

### D5. Skips name their prerequisite

A shared helper in the UI test target, `UITestPrerequisite`, throws `XCTSkip` with a fixed
message:
- `serverWrites()`: "Needs a test backend for saving (follow-up change ui-test-backend)."
- `serverDownloads()`: "Needs a test backend for downloads (follow-up change ui-test-backend)."
  Opening an attachment downloads it; the fixture has metadata only.
- `realAccount()`: skipped with "Needs a real account: set …" unless `BW_TEST_SERVER_URL`,
  `BW_TEST_EMAIL` and `BW_TEST_PASSWORD` are set. `xcodebuild` passes them to the test runner only
  with the `TEST_RUNNER_` prefix (`TEST_RUNNER_BW_TEST_EMAIL` and so on). With them, the journey
  runs against that server, still with the in-memory keychain.
- `biometrics()`: "Needs simulated Touch ID (follow-up change ui-test-biometrics)."
- `knownAppBug(_:fixedBy:)`: "Known app bug: … (to be fixed by …)." Only for a bug that crashes the
  app, so the rest of the journey cannot run. A bug that only makes a check fail is wrapped in
  `XCTExpectFailure` naming the follow-up change instead: the test keeps running and starts
  failing once the bug is fixed, so the marker gets removed (see Findings).

Tests that need a server for only their last step (for example, opening the create sheet locally
and then saving) keep the local part and skip at the save step.

### D6. Release builds stay clean

All new app code is inside `#if DEBUG`, like `UITestFixtures` today. Verified on the Release
build: the binary contains none of the `--ui-test-` argument strings.

### D7. No system-wide shortcuts in UI tests

UI tests never send key combinations that macOS handles system-wide. ⌘⇧Q is "Log Out <user>" in
the Apple menu, and ⌃⌘Q locks the screen. A test that sends ⌘⇧Q while Prizm is not frontmost, or
while Prizm's own menu item is disabled, logs the developer out of macOS. That happened on
2026-10-25 with the converted `testSignOutKeyboardShortcut`, which is therefore removed, not
converted.

Related app finding, out of scope here: Prizm binds "Sign Out…" to ⌘⇧Q (`App/PrizmApp.swift`, the
`CommandGroup(after: .appInfo)` block), the same combination as the system's Log Out. A UI run that
sent it logged the developer out of macOS. Fixed in `fix-ui-journey-findings` by removing the
shortcut.

### D8. Shared query helpers for how SwiftUI exposes the app

The old tests assumed identifiers and element types that SwiftUI on macOS 26 does not expose. The UI
test target gets one support file (`UITestSupport.swift`) with a base class and helpers, so each
workaround is written and explained once:

| What the app shows | What accessibility exposes | Helper |
|---|---|---|
| `NavigationSplitView` with `vault.navigationSplit` | no identifier; the sidebar is `outlines["Sidebar"]` | `sidebar`, `waitForVaultBrowser()` |
| Sidebar rows with `sidebar.*` identifiers | no identifier; title as label or value | `sidebarRow(_:)`, `selectSidebarRow(_:)` |
| Field row with children `masked.<label>.value`, `.toggle` | the row's `field.<label>` overrides the children's identifiers | `fieldValue(_:)`, `revealButton(_:)` |
| `Text` | often the value, not the label | `XCUIElement.text`, `waitForText(_:timeout:)` |
| Selectable `Text` (`.textSelection(.enabled)`) | an outer element with the identifier that keeps its first value, and an inner text that follows changes | `displayedText` |
| "+" menu | `MenuButton` titled "New Item" | `menuButtons["create.button.newItem"]` |
| Segmented picker | radio buttons | `radioButtons["Password"]` |
| `Stepper` | increment and decrement arrows, not buttons | `stepper.incrementArrows` |

macOS restores the last window size, which can be too small for the whole sidebar (900×450 on
the test Mac). Scrolling the sidebar from a test proved unreliable: a row the outline has not
rendered reports a frame at the screen edge, and `isHittable` is true for a row hidden under the
toolbar, so the click hits the toolbar. `waitForVaultBrowser()` therefore zooms a window shorter
than 700 pt (Window → Zoom), and `selectSidebarRow` asserts the row is visible instead of
scrolling.

`PrizmUITestCase` prints the app's UI hierarchy into the log on every failure, so a failure can be
classified from the log without re-running the suite.

Launched by XCUITest, the app gets no "reopen" event, so SwiftUI shows its window only when macOS
restores one from the saved window state. With `-ApplePersistenceIgnoreState YES`, or after a run
that left no window in the saved state, the app starts without a window. (This change first named
the launch argument as the cause; the run on 2026-10-26 showed the same symptom without it.)
`fix-ui-journey-findings` makes `launch(in:)` open a window with File → New Window when
there is none, after fixing that menu item. Selecting test classes with `xcodebuild -only-testing`
works.

## Findings

App bugs found by the converted journeys, confirmed by hand where noted. They are out of scope here
and are fixed together in the follow-up change `fix-ui-journey-findings`, one commit per bug. The
tests mark them so the suite stays green and the marker fails once the bug is fixed.

| Finding | Test | Marker | Follow-up |
|---|---|---|---|
| ⌘N while Trash is selected crashes the app | `CreateItemJourneyTests.testCmdN_isNoOp_inTrash` | `knownAppBug` | `fix-ui-journey-findings` |
| The "+" button stays visible in Trash, against spec `list-column-header` | `CreateItemJourneyTests` (hidden in Trash) | `XCTExpectFailure` | `fix-ui-journey-findings` |
| Locking does not clear the item selection: the decrypted item stays in memory and Item → Edit stays enabled (§III) | `EditItemJourneyTests.testItemMenu_followsSelectionAndLock` | `XCTExpectFailure` | `fix-ui-journey-findings` |
| Arrow keys do not move the selection in the sidebar or the item list (§VIII), confirmed by hand | `KeyboardNavigationTests.testArrowKeysNavigate*` | `XCTExpectFailure` | `fix-ui-journey-findings` |
| "Sign Out…" uses ⌘⇧Q, the system's Log Out shortcut (D7) | none (test removed) | none | `fix-ui-journey-findings` |
| VoiceOver reads "bullet bullet …" after Reveal while the password is visible (§VIII), confirmed with VoiceOver. A selectable `Text` keeps its first accessibility value; the generator preview shows the same in UI runs | `VaultBrowserJourneyTests.testRevealToggleShowsPlaintext` | `XCTExpectFailure` | `fix-ui-journey-findings` |

## Risks / Trade-offs

- **[Medium] Fixture changes ripple into other journeys.** → D3 keeps the existing items, and
  `VerificationCodeJourneyTests` must still pass 9 of 9.
- **[Low] The biometric defaults isolation covers reads only.** A write through
  `UserDefaults.set` still goes to the persistent domain. It holds because every write in the
  unlock flow sits behind a read of the isolated keys. The Settings toggle for Touch ID writes
  directly; no UI test uses it, and `ui-test-biometrics` must isolate it before one does.
- **[Low] `UserDefaults` is not isolated.** The password generator journey writes generator
  options to the developer's settings for the app. Accepted. Isolating preferences would need a
  defaults abstraction across the app.
- **[Low] UI tests drive the screen** for several minutes. Documented in `DEVELOPMENT.md`.

## Open Questions

1. Should CI run the `PrizmUITests` scheme? It needs a macOS runner with a GUI session and a signed
   test runner. The maintainer decides.
2. Test backend or Vaultwarden rig for the saving journeys (`ui-test-backend`): decided once the
   rig exists.
