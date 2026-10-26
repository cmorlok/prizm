# Proposal

## Why

**Criticality:** P0 (Critical: nobody except the maintainer can build Prizm with signing)

A signed build of the app target fails for every contributor, in Xcode and on the command line.
Two independent regressions in `Prizm/Prizm.xcodeproj/project.pbxproj` cause this, and neither is
caught by CI, because CI and the release workflow build with `CODE_SIGNING_ALLOWED=NO`.

**1. The app target has no bundle identifier.**
- `923fa5b` (org support, #41, 2026-04-19) deleted `PRODUCT_BUNDLE_IDENTIFIER = de.b0x42.Prizm`
  from both app configurations (Debug and Release). Nothing in the change mentions it, so it was
  probably an accidental side effect of editing the project.
- A signed build stops with: "Bundle identifier is missing. Prizm doesn't have a bundle
  identifier."
- Unsigned builds don't check this. **v1.4.0 to v1.5.0 were therefore built without a bundle
  identifier.** `Info.plist` is generated (`GENERATE_INFOPLIST_FILE = YES`), and the committed
  `Prizm/Prizm/Info.plist` is empty. Confirmed on an installed v1.5.0: its `Info.plist` has no
  `CFBundleIdentifier`, and it stores its settings in the defaults domain `Prizm`
  (`~/Library/Preferences/Prizm.plist`) instead of `de.b0x42.Prizm`.

**2. The maintainer's Team ID is hard-coded in the app target.**
- `c95e172` (v1-release-prep, 2026-04-03, in every release since v1.0.0) put
  `DEVELOPMENT_TEAM = <maintainer's Team ID>` into both app configurations.
- Target build settings override the target's base configuration, so the `DEVELOPMENT_TEAM` that
  contributors set in `Prizm/LocalConfig.xcconfig` (as `DEVELOPMENT.md` asks) is ignored.
- This breaks the existing requirement "Team ID excluded from repo" in
  `openspec/specs/keychain-signing-config/spec.md`: "The git repository SHALL NOT contain the
  developer's Team ID or Apple ID in any committed file."

**3. A fixed bundle identifier can't work for contributors anyway.**
- App IDs are unique across all Apple developer teams. With only the team fixed, a contributor's
  build fails with: "The app identifier "de.b0x42.Prizm" cannot be registered to your development
  team because it is not available." (Reproduced 2026-10-25 with a non-maintainer team.)
- So `DEVELOPMENT.md`'s promise "A free Apple ID ("Personal Team") works for local builds" has not
  been true for anyone but the maintainer since the bundle identifier was introduced.

## Origin of the current behaviour

| Issue | Origin | Evidence |
|---|---|---|
| Missing bundle identifier | Accidental | Removed in `923fa5b` without mention; signed builds were not run in CI |
| Hard-coded Team ID | Accidental | Added in `c95e172`, the same commit that introduced `LocalConfig.xcconfig.template` and the "Team ID never touches the repo" rule. Typically written by Xcode when signing is set in the target editor. |
| Fixed bundle ID for everyone | Wrong premise | `DEVELOPMENT.md` and the template assume that only the Team ID differs per developer |

## What Changes

- **The bundle identifier is always set.** The app target uses
  `PRODUCT_BUNDLE_IDENTIFIER = $(PRIZM_BUNDLE_IDENTIFIER:default=de.b0x42.Prizm)`.
  - CI, releases and the maintainer get `de.b0x42.Prizm`, the identifier of v1.0.0 to v1.3.0.
  - A contributor sets `PRIZM_BUNDLE_IDENTIFIER` to an identifier they own, in their git-ignored
    `LocalConfig.xcconfig`.
- **The Team ID comes only from `LocalConfig.xcconfig`.** `DEVELOPMENT_TEAM` is removed from the
  app target, so the documented setup works again.
- **CI guards both.**
  - The unsigned CI build fails when the built app has no `CFBundleIdentifier`.
  - A check fails when a `DEVELOPMENT_TEAM` value is committed in the project file.
- **Docs.**
  - `LocalConfig.xcconfig.template` and `DEVELOPMENT.md` explain `PRIZM_BUNDLE_IDENTIFIER`.
  - The command-line build examples gain `-allowProvisioningUpdates`; without it, `xcodebuild`
    can't create the development profile.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `keychain-signing-config`: adds a requirement for the app's bundle identifier and a CI guard.
  The existing requirement "Team ID excluded from repo" is unchanged in wording and is met again.

## Non-Goals

- Signing or notarizing releases. Releases stay unsigned as today; signing is the maintainer's
  decision.
- Migrating settings written by v1.4.0 to v1.5.0 from the `Prizm` domain. Decided against to keep
  the fix free of migration code; the CHANGELOG states the impact (design.md, D4).
- The test targets' identifiers (`de.b0x42.de.PrizmTests`, `de.b0x42.de.PrizmUITests`). Unit and
  UI tests run with a non-maintainer team without an override (tasks 4.1, 4.3).
- The keychain access group. It is `$(AppIdentifierPrefix)com.prizm`, independent of the bundle
  identifier, so stored credentials are not affected.

## Dependencies

None. It blocks every change that needs a signed local build or test run.

## Impact

- **Project:** `Prizm/Prizm.xcodeproj/project.pbxproj`, app target Debug and Release only.
- **Config and docs:** `Prizm/LocalConfig.xcconfig.template`, `DEVELOPMENT.md`, `CHANGELOG.md`.
- **CI:** `.github/workflows/ci.yml` gets two guard steps.
- **Tests:** one unit test that the app bundle has a non-empty bundle identifier.
- **Users of v1.4.0 to v1.5.0:** after the update, `UserDefaults` is read from the
  `de.b0x42.Prizm` domain again, so the values 1.4.0 to 1.5.0 wrote to `Prizm` are not seen:
  "Unlock with Touch ID", the Touch ID enrollment offer, the password generator options and the
  "Last synced" time (design.md, D4). Vault data and credentials are in the keychain and are not
  affected. Covered in the CHANGELOG entry.
- **Security review:** not required. No code path changes; signing settings and CI only.

## Estimate

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm the released app's `CFBundleIdentifier` and defaults domain | 0.25 d |
| 2 | Failing test and CI guards | 0.25 d |
| 3 | Project settings, template, docs, CHANGELOG | 0.25 d |
| 4 | Signed build and tests with a non-maintainer team; unsigned CI build | 0.25 d |
| **Total** | | **1 d** |
