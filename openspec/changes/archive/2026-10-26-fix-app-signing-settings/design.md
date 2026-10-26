# Design

## Context

**App target today** (`Prizm/Prizm.xcodeproj/project.pbxproj`, configurations
`434D9EC62F670B9E00052BCB` Debug and `434D9EC72F670B9E00052BCB` Release):
- `baseConfigurationReference` is `LocalConfig.xcconfig` (git-ignored, copied from
  `Prizm/LocalConfig.xcconfig.template`).
- `DEVELOPMENT_TEAM = <maintainer's Team ID>` is set in the target. Target settings win over the base
  configuration, so `LocalConfig.xcconfig` can't change the team.
- `PRODUCT_BUNDLE_IDENTIFIER` is not set anywhere for the app target. `GENERATE_INFOPLIST_FILE =
  YES`, and `Prizm/Prizm/Info.plist` is an empty dictionary, so nothing else provides one.
- `CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_ENTITLEMENTS = Prizm/Prizm.entitlements`.

**Test targets.** `PrizmTests` (`de.b0x42.de.PrizmTests`) and `PrizmUITests`
(`de.b0x42.de.PrizmUITests`) have their own identifiers, no team and no base configuration.

**CI and releases** (`.github/workflows/ci.yml`, `release.yml`) copy the template and build with
`CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`. Xcode doesn't require a
bundle identifier then, which is why both regressions went unnoticed.

**What depends on the bundle identifier.**
- `UserDefaults.standard` (its domain is the bundle identifier). Keys written by the app:
  - `biometricUnlockEnabled` and `biometricEnrollmentPromptShown`
    (`Data/Repositories/AuthRepositoryImpl.swift:451-619`)
  - the last-sync timestamp per account (`Data/Repositories/SyncTimestampRepositoryImpl.swift`)
- The sandbox container, `~/Library/Containers/<bundle id>`, for signed sandboxed builds.
  Releases are unsigned, so their entitlements, including the sandbox, are not applied.
- Not the keychain. `KeychainService` uses service `com.prizm`
  (`Data/Keychain/KeychainService.swift:58`) and the access group
  `$(AppIdentifierPrefix)com.prizm` (`Prizm.entitlements`).

**Observed on 2026-10-25** (signed Debug build via `xcodebuild`, non-maintainer team in
`LocalConfig.xcconfig`):

| Setup | Result |
|---|---|
| Current project | `error: Bundle identifier is missing. Prizm doesn't have a bundle identifier.` |
| `de.b0x42.Prizm` restored, target team removed, no `-allowProvisioningUpdates` | `No profiles for 'de.b0x42.Prizm' were found … pass -allowProvisioningUpdates to xcodebuild` |
| Same, with `-allowProvisioningUpdates` | `The app identifier "de.b0x42.Prizm" cannot be registered to your development team because it is not available.` |
| `$(PRIZM_BUNDLE_IDENTIFIER:default=de.b0x42.Prizm)`, variable unset | Resolves to `de.b0x42.Prizm` (same error as above), so the default syntax works |

**Released v1.5.0, checked on 2026-10-25** (installed from the release DMG on a Mac that never had
another release; all other Prizm preferences removed first):
- `plutil -p /Applications/Prizm.app/Contents/Info.plist` lists no `CFBundleIdentifier`.
- After one launch and quit, the only new preferences are the defaults domain `Prizm`
  (`~/Library/Preferences/Prizm.plist`). No sandbox container is created (unsigned build).
- v1.0.0 to v1.3.0 had `de.b0x42.Prizm` (`c95e172`), so users who started on those still have
  their older values in `de.b0x42.Prizm`.

## Goals / Non-Goals

**Goals**
- A fresh clone builds and tests with signing on any developer's team, after the documented
  `LocalConfig.xcconfig` setup.
- CI and releases get the same bundle identifier as v1.0.0 to v1.3.0, with no change to their
  workflow commands.
- No Team ID and no personal bundle identifier in committed files.
- CI catches both regressions next time.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Bundle identifier: overridable default in the target

`PRODUCT_BUNDLE_IDENTIFIER = "$(PRIZM_BUNDLE_IDENTIFIER:default=de.b0x42.Prizm)";` in both app
configurations.
- `PRIZM_BUNDLE_IDENTIFIER` is a project-specific variable. When `LocalConfig.xcconfig` doesn't set
  it, the `:default=` operator yields `de.b0x42.Prizm`.
- So existing `LocalConfig.xcconfig` files keep working unchanged, and CI and release builds need
  no change.

**Rejected alternatives**
- *Set `PRODUCT_BUNDLE_IDENTIFIER` only in the template.* An existing local
  `LocalConfig.xcconfig` (copied from the old template) would have no value, and the build would
  fail again.
- *Hard-code `de.b0x42.Prizm` in the target.* Contributors couldn't override it, because target
  settings beat the base configuration. That's issue 3.
- *A new tracked xcconfig with `#include? "LocalConfig.xcconfig"`.* Cleaner layering, but it
  changes how the project is configured. Too much for a fix; can be proposed separately.

### D2. Team: only from `LocalConfig.xcconfig`

Remove `DEVELOPMENT_TEAM = <maintainer's Team ID>;` from both app configurations. The team then comes from the
base configuration, as `DEVELOPMENT.md` and the template already describe. The maintainer's own
`LocalConfig.xcconfig` must contain their Team ID, which the template already asks for.

### D3. CI guards

In `.github/workflows/ci.yml`:
1. **After the unsigned build:** fail with its own message if the built
   `Prizm.app/Contents/Info.plist` does not exist. Then read `CFBundleIdentifier` with `PlistBuddy`. Fail if it is empty or missing, which
   catches issue 1 (only signed builds detect it today). Also fail if it is not exactly
   `de.b0x42.Prizm`: CI builds with the unchanged template, so any other value means a typo in
   the default or a personal identifier committed to the template. A release with such an
   identifier would read its settings from another domain (see D4).
2. **Before building:** fail if `project.pbxproj` sets a non-empty team: `DEVELOPMENT_TEAM =
   <value>;`, the conditional form `"DEVELOPMENT_TEAM[sdk=…]" = <value>;`, or
   `DevelopmentTeam = <value>;` under TargetAttributes (the forms Xcode writes). This catches
   issue 2, and enforces "Team ID excluded from repo" mechanically.

The same `CFBundleIdentifier` property is also checked by a unit test (task 2.1), so a local test
run catches it too.

### D4. No migration of v1.4.0–v1.5.0 settings

After the fix, `UserDefaults` is read from `de.b0x42.Prizm` again, the domain of v1.0.0 to v1.3.0.
v1.4.0 to v1.5.0 wrote to the domain `Prizm` (Context), which the fixed app does not read.

What users of v1.4.0 to v1.5.0 lose on updating:
- "Unlock with Touch ID" (`biometricUnlockEnabled`) is off until they enable it again.
- The Touch ID enrollment offer (`biometricEnrollmentPromptShown`) may appear once more.
- Password generator options (`PasswordGeneratorConfig`, `Domain/Utilities/PasswordGeneratorConfig.swift:48-62`)
  are back to their defaults.
- "Last synced" (`SyncTimestampRepositoryImpl`) is empty until the next sync.

Vault data and credentials are in the keychain and are not affected.

**The Touch ID keychain item.** The biometric vault-key item written by v1.4.0 to v1.5.0
(`KeychainKey.biometricVaultKey`) survives the update while the switch shows "off". It is replaced
when the user enables Touch ID again (`enableBiometricUnlock`) and deleted on sign-out
(`signOut` calls `disableBiometricUnlock`, `Data/Repositories/AuthRepositoryImpl.swift:384-396`).
It stays protected by Touch ID (`.biometryCurrentSet`) until then.

Users who started on v1.0.0 to v1.3.0 get their older values from `de.b0x42.Prizm` back. A stale
"Touch ID on" without a matching keychain item is already handled: unlock finds no item, clears
the flag and offers re-enrollment after the next password unlock
(`Data/Repositories/AuthRepositoryImpl.swift:521-531`).

**Rejected alternative:** a one-time migration of the known keys from `Prizm` to
`de.b0x42.Prizm` at launch. It is feasible (releases are unsigned and not sandboxed, so they can
read the old domain) and would also keep the Touch ID switch consistent with the surviving item.
Decided on 2026-10-25 to keep this fix free of migration code and state the impact in the
CHANGELOG instead.

### D5. Command-line builds need `-allowProvisioningUpdates`

`DEVELOPMENT.md`'s `xcodebuild` examples add `-allowProvisioningUpdates`. Automatic signing only
creates the development profile from the command line with this flag; the Xcode GUI does it
implicitly. It requires the developer's Apple ID in Xcode → Settings → Accounts.

## Risks / Trade-offs

- **[Low] The maintainer's local `LocalConfig.xcconfig` has no Team ID.** Their signed builds then
  fail with "requires a development team". → The fix is the documented setup. Mentioned in the PR
  description.
- **[Low] `:default=` is an Xcode build-setting operator.** Verified with the current Xcode
  (2026-10-25). It has existed for several Xcode versions, but it isn't documented in the build
  settings reference.
- **[Low] Users of v1.4.0–v1.5.0 see two settings reset** (D4, confirmed). Stated in the CHANGELOG.

## Open Questions

1. Should releases be signed and notarized? Out of scope; the maintainer's decision.
