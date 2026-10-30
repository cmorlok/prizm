# Design

## Context

- `AuthRepositoryImpl` reads `biometricUnlockEnabled` in `biometricUnlockAvailable` and writes it in
  `enableBiometricUnlock`, `disableBiometricUnlock`, the biometric unlock error paths and `signOut`
  (with `biometricEnrollmentPromptShown`). `signOut()` also calls `disableBiometricUnlock()`, so
  every test that signs out through the real repository writes the key, though the key name never
  appears in that test.
- `UnlockViewModel` reads both keys for the enrollment offer (`checkEnrollmentOrSync`, run after
  every successful unlock) and writes `biometricEnrollmentPromptShown`.
- `BiometricUnlockToggleViewModel` reads `biometricUnlockEnabled` for its initial state.
- `UITestFixtures.isolateBiometricDefaults` puts both keys into the volatile argument domain for UI
  tests; unit tests have no equivalent.

## Decisions

### D1. Inject the store, keep the key names

Each of the three types gets a required `defaults: UserDefaults` in its initializer and keeps it in
a private property. Key names stay as they are, so stored settings carry over. There is no default
value: with `= .standard` a test that forgets the argument would silently use the real store, which
is exactly how the `signOut` writers above went unnoticed. The app passes `.standard` explicitly
(`AppContainer`, `BiometricUnlockToggle`).

`AppContainer.preferences` is that one store (`.standard`); `AppContainer`, `makeUnlockViewModel`
and `SettingsView` → `BiometricUnlockToggle` all pass it. The key names live once in
`BiometricPreferenceKey` (Domain), so a typo cannot split the state (code review 2026-10-30).

All three types are `@MainActor` classes, not actors, and so are their tests; passing the
non-`Sendable` `UserDefaults` stays in one isolation domain. No suite-name `String` or
`nonisolated(unsafe)` is needed (unlike `SyncTimestampRepositoryImpl` or `FaviconLoader`).

### D2. One private suite per test

Tests call `makePrivateDefaults()` (an `XCTestCase` helper), which names the suite after the test
method and the call site, empties it first and removes it again in a teardown block. A name per
test method and call site rather than a UUID: a test runs in one process at a time, and a UUID per
call would leave a new suite file on every run (code review 2026-10-30). Where a test class builds a view model and a repository, both get the same suite. Do not copy
the fixed per-class suite names of `SyncTimestampRepositoryImplTests` or
`PasswordGeneratorViewModelTests`: two stores made in one test must stay apart.

**Rejected:** a lock or serial execution for the two classes. It hides the race but keeps changing
the developer's real settings.

### D3. The app as unit-test host starts signed out

Unit tests run inside the app. Without a `--ui-test-*` argument the host used the real keychain,
showed the developer's unlock screen, and its Touch ID path wrote `false` to both keys in
`.standard` when the biometric item was missing. `UITestFixtures.isUnitTestHost`
(`XCTestConfigurationFilePath` set, no UI-test state) makes `AppContainer` use the empty in-memory
keychains of the signed-out UI-test state. It does not call `isolateBiometricDefaults()`: the
volatile argument domain it writes is read by every store in the process, private suites included,
and would override the tests' own values (code review 2026-10-30).

**Not done (code review 2026-10-30):**
- Moving the two flags behind `AuthRepository`, so only the repository takes a store: cleaner, but a
  protocol change beyond this fix; one shared store and one key definition remove the drift risk.
- Guarding private suites against the argument domain: nothing in the unit tests sets these keys
  there (see D3), and `UITestSeamTests` restores the argument domain it changes.

## Risks / Trade-offs

- **A test passes `.standard` on purpose or by copy-paste.** → Task 2.2 greps the tests for
  `.standard` next to these initializers; the guard tests of task 1.1 snapshot the two keys in
  `.standard` before and after.
- **Isolation cannot be proven for parallel runs.** → The deterministic check is per test: its
  writes land in its own store and `.standard` is unchanged. Three green full runs (task 3.1) are
  supporting evidence only.
