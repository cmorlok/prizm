# Proposal

## Why

`AuthRepositoryImplBiometricTests.testDisableBiometricUnlock_clearsPreferenceAndKeychain` fails at
random (seen 2026-10-30 on fix/027; the rerun passed). `AuthRepositoryImplBiometricTests` and
`UnlockViewModelBiometricTests` set and remove `biometricUnlockEnabled` and
`biometricEnrollmentPromptShown` in `UserDefaults.standard`, and every test that runs the real
`AuthRepositoryImpl.signOut()` writes `biometricUnlockEnabled = false` there too (through
`disableBiometricUnlock()`): `AuthRepositoryImplTests`, `KdfLoginTests`, `KeyLifecycleTests`. Xcode
runs test classes in parallel processes, and all of them share the app's preferences domain through
`cfprefsd`. When another class writes the key between one class's write and read, the assertion
fails.

The unit tests are hosted in the app, so `UserDefaults.standard` is the real Prizm preferences
domain of the developer's Mac. Every unit-test run deletes the developer's real Touch ID setting
("Unlock with Touch ID" off, and the enrollment offer shown again). The UI tests already isolate
these two keys (`UITestFixtures.isolateBiometricDefaults`); the unit tests do not.

### Origin of the current behaviour

**Accidental.** The code reads and writes `UserDefaults.standard` directly
(`AuthRepositoryImpl`, `UnlockViewModel`, `BiometricUnlockToggleViewModel`), so the tests had no
other store to use. Other types already take an injected store (`SyncTimestampRepositoryImpl`,
`PasswordGeneratorViewModel`, `ClipboardService`), and their tests use a private suite.

## What Changes

- `AuthRepositoryImpl`, `UnlockViewModel` and `BiometricUnlockToggleViewModel` take a required
  `defaults: UserDefaults` and use it for the two biometric keys. No default value: the compiler
  then finds every test that would otherwise use the real store. The app passes `.standard`.
- Every unit test that builds one of these types, directly or through a helper, passes a private
  `UserDefaults(suiteName:)` created per test and removed in `tearDown`.
- No behaviour change in the app.

## Capabilities

### New Capabilities
- `unit-test-isolation`: unit tests do not share or change persisted preferences.

### Modified Capabilities
_None._

## Non-Goals

- Moving the two keys into a typed preferences store.
- Other preferences in unit tests. Checked 2026-10-30: no test writes `UserDefaults.standard`
  directly except the two biometric classes, and no other app code reachable from unit tests
  writes it indirectly (`PasswordGeneratorConfig.save/load` default to `.standard`, but their tests
  pass a suite). `UITestFixtures.isolateBiometricDefaults` and `UITestSeamTests` already use their
  own store and stay unchanged.

## Dependencies

None.

## Impact

- **Data / Presentation / App:** a required `UserDefaults` in three types; `AppContainer` (the
  repository and `makeUnlockViewModel`) and `BiometricUnlockToggle` pass `.standard`.
- **Tests:** every class that builds one of the three types, at least
  `AuthRepositoryImplBiometricTests`, `UnlockViewModelBiometricTests`, `AuthRepositoryImplTests`,
  `KdfLoginTests`, `KeyLifecycleTests`, `UnlockViewModelTests`, `RootViewModelLockTests` (its mock
  dependencies), `BiometricUnlockToggleViewModelTests`; the compiler lists the rest.
- **No new dependencies.** No security review needed (no key handling changes; the Keychain items
  are unchanged).
