# Tasks

Write a failing test first for each task (§IV).

## 0. Checkpoint

- [x] 0.1 Spec challenge by a fresh agent (Lane B), 2026-10-30, against develop `ce678163`. Done: 2 blockers (`signOut()` writes the key through `disableBiometricUnlock()` in three more test classes; a default `.standard` lets tests silently use the real store), 3 should-fixes, 3 nits, all adopted.

## 1. Tests first

- [ ] 1.1 Behaviour-red guard tests against the current initializers: enable, disable and `signOut()` on `AuthRepositoryImpl` leave `biometricUnlockEnabled` and `biometricEnrollmentPromptShown` in `UserDefaults.standard` unchanged (snapshot before, compare after, restore). They fail today. Then the same tests with a private store (scenario "A test's writes stay in its own store"; red: compile).
- [ ] 1.2 Failing tests (red: compile): `UnlockViewModel` and `BiometricUnlockToggleViewModel` read the keys from the injected store (scenario "A view model reads the injected store").

## 2. Inject the store

- [ ] 2.1 Required `defaults: UserDefaults` (no default value) in `AuthRepositoryImpl`, `UnlockViewModel`, `BiometricUnlockToggleViewModel` (design D1); `AppContainer` and `BiometricUnlockToggle` pass `.standard`.
- [ ] 2.2 Every test that builds one of the three types passes a private store per test (D2): at least `AuthRepositoryImplBiometricTests`, `UnlockViewModelBiometricTests`, `AuthRepositoryImplTests`, `KdfLoginTests`, `KeyLifecycleTests`, `UnlockViewModelTests`, `RootViewModelLockTests`, `BiometricUnlockToggleViewModelTests`, and whatever else the compiler lists. `grep -rn "UserDefaults.standard\|defaults: .standard" Prizm/PrizmTests` finds no use with these types except the guard snapshots.
- [ ] 2.3 The app as unit-test host starts signed out with in-memory keychains (D3); `AppContainer.preferences` is the one store; keys in `BiometricPreferenceKey`. Tests: `UITestSeamTests.test_unitTestHost_isDetected`, `test_appContainer_inTheUnitTestHost_hasNoStoredSession` (red 20261030T171836Z: the host saw the developer's stored login).

## 3. Close

- [ ] 3.1 Full unit run three times in a row, all green (supporting evidence; the guard tests are the deterministic check).
- [ ] 3.2 Hand check (scenario "A unit-test run keeps the developer's settings"): with "Unlock with Touch ID" on and the enrollment offer already shown, run the unit tests; the setting is still on and the offer does not reappear at the next unlock.
- [ ] 3.3 CHANGELOG (developer-facing "Tests" line).
- [ ] 3.4 `openspec validate fix-biometric-test-isolation --type change --strict`, `/opsx:verify`.
- [ ] 3.5 Archive the change.
