# Tasks

Write a failing test first for each task (§IV).

## 0. Checkpoint

- [x] 0.1 Spec challenge by a fresh agent (Lane B), 2026-10-30, against develop `ce678163`. Done: 2 blockers (`signOut()` writes the key through `disableBiometricUnlock()` in three more test classes; a default `.standard` lets tests silently use the real store), 3 should-fixes, 3 nits, all adopted.

## 1. Tests first

- [x] 1.1 Behaviour-red guard tests against the current initializers: enable, disable and `signOut()` on `AuthRepositoryImpl` leave `biometricUnlockEnabled` and `biometricEnrollmentPromptShown` in `UserDefaults.standard` unchanged (snapshot before, compare after, restore). They fail today. Then the same tests with a private store (scenario "A test's writes stay in its own store"; red: compile). Done: `BiometricDefaultsIsolationTests.testEnableDisableAndSignOut_leaveTheRealPreferencesUnchanged`, behaviour-red 20261030T165033Z against the old initializers, then switched to a private store.
- [x] 1.2 Failing tests (red: compile): `UnlockViewModel` and `BiometricUnlockToggleViewModel` read the keys from the injected store (scenario "A view model reads the injected store"). Done: `testToggleViewModel_readsTheInjectedStore`, `testUnlockViewModel_readsTheEnrollmentStateFromTheInjectedStore`. Deviation: written together with 2.1, without a separate compile-red run. Code review: the unlock test asserts that both runs reach the vault.

## 2. Inject the store

- [x] 2.1 Required `defaults: UserDefaults` (no default value) in `AuthRepositoryImpl`, `UnlockViewModel`, `BiometricUnlockToggleViewModel` (design D1); `AppContainer` and `BiometricUnlockToggle` pass `.standard`. Done; green 20261030T165302Z.
- [x] 2.2 Every test that builds one of the three types passes a private store per test (D2): at least `AuthRepositoryImplBiometricTests`, `UnlockViewModelBiometricTests`, `AuthRepositoryImplTests`, `KdfLoginTests`, `KeyLifecycleTests`, `UnlockViewModelTests`, `RootViewModelLockTests`, `BiometricUnlockToggleViewModelTests`, and whatever else the compiler lists. `grep -rn "UserDefaults.standard\|defaults: .standard" Prizm/PrizmTests` finds no use with these types except the guard snapshots. Done via `makePrivateDefaults()` (named per test method and call site since the code review); `MockRootDependencies(defaults:)`. The grep finds no use outside `BiometricDefaultsIsolationTests` (snapshots) and the helper's comment (2026-10-30).
- [x] 2.3 The app as unit-test host starts signed out with in-memory keychains (D3); `AppContainer.preferences` is the one store; keys in `BiometricPreferenceKey`. Tests: `UITestSeamTests.test_unitTestHost_isDetected`, `test_appContainer_inTheUnitTestHost_hasNoStoredSession` (red 20261030T171836Z: the host saw the developer's stored login). Done: red 20261030T171836Z (the host saw the developer's stored login), green 20261030T172010Z.

## 3. Close

- [x] 3.1 Full unit run three times in a row, all green (supporting evidence; the guard tests are the deterministic check). Done on the final code: 20261030T181937Z, 181958Z, 182008Z (1306 passed, 0 failed each); before the code review also 20261030T165302Z, 165336Z, 165347Z.
- [x] 3.2 Hand check (scenario "A unit-test run keeps the developer's settings"): with "Unlock with Touch ID" on and the enrollment offer already shown, run the unit tests; the setting is still on and the offer does not reappear at the next unlock. Done: Christian, 2026-10-30, Debug build of the batch-2 integration branch: Touch ID unlock on and working, unit run 20261030T180517Z (1362 passed) with the app as host, then Touch ID offered at unlock, no enrollment offer, setting still on.
- [x] 3.3 CHANGELOG (developer-facing "Tests" line). Done (CHANGELOG, Unreleased).
- [x] 3.4 `openspec validate fix-biometric-test-isolation --type change --strict`, `/opsx:verify`. Done 2026-10-30: `validate --strict` valid; `/code-review` high, 9 findings, 7 fixed, 2 declined with reasons (design D3); `/opsx:verify`: 2/2 requirements, 4/4 scenarios covered, no critical issues or warnings.
- [x] 3.5 Archive the change. Done 2026-10-30 (`openspec archive`).
