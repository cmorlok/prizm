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
1. **After the unsigned build:** read `CFBundleIdentifier` from the built
   `Prizm.app/Contents/Info.plist` with `PlistBuddy`, and fail if it is empty or missing. This
   catches issue 1, which only signed builds detect today.
2. **Before building:** fail if `project.pbxproj` contains `DEVELOPMENT_TEAM = <value>;` with a
   non-empty value. This catches issue 2, and enforces "Team ID excluded from repo" mechanically.

The same `CFBundleIdentifier` property is also checked by a unit test (task 2.1), so a local test
run catches it too.

### D4. No migration of v1.4.0–v1.5.0 settings

After the fix, `UserDefaults` is read from `de.b0x42.Prizm` again, the domain of v1.0.0 to v1.3.0.
Settings written by v1.4.0 to v1.5.0 stay where those builds put them. Task 1.1 confirms where that
is.

The impact is small and errs on the safe side:
- "Unlock with Touch ID" shows as off until the user enables it again.
- "Last synced" is empty until the next sync.

Migrating would mean reading another app's preferences domain, which a sandboxed signed build
can't do. The CHANGELOG states the impact instead.

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
- **[Low] Users of v1.4.0–v1.5.0 see two settings reset** (D4). Stated in the CHANGELOG.

## Open Questions

1. Should releases be signed and notarized? Out of scope; the maintainer's decision.
