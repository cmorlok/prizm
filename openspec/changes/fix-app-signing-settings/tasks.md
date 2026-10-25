# Tasks

Estimates are ideal engineer-days. Write a failing test first (§IV). No dependencies.

## 1. Confirm the released state (0.25 d)

- [ ] 1.1 On a Mac with a released v1.4.x or v1.5.0 installed, record in design.md, Context: `plutil -p /Applications/Prizm.app/Contents/Info.plist | grep -i bundle` and `defaults domains | tr ',' '\n' | grep -i prizm`, plus the bundle identifier of v1.3.0 for comparison. Adjust D4 if the old settings turn out to be reachable.

## 2. Failing test and CI guards (0.25 d)

- [ ] 2.1 Failing unit test (`PrizmTests/App/AppBundleConfigurationTests.swift`): `Bundle.main` (the test host, the Prizm app) has a non-empty `bundleIdentifier`. It fails today.
- [ ] 2.2 `ci.yml`, before the build: fail when `Prizm/Prizm.xcodeproj/project.pbxproj` contains a non-empty `DEVELOPMENT_TEAM` value, with a message pointing to `LocalConfig.xcconfig`. Check it locally against the current project (must fail) and the fixed one (must pass).
- [ ] 2.3 `ci.yml`, after the unsigned build: fail when the built `Prizm.app/Contents/Info.plist` has no or an empty `CFBundleIdentifier`. The build needs a known `-derivedDataPath` for this.

## 3. Fix (0.25 d)

- [ ] 3.1 App target, Debug and Release: remove the hard-coded `DEVELOPMENT_TEAM` (design D2) and add `PRODUCT_BUNDLE_IDENTIFIER = "$(PRIZM_BUNDLE_IDENTIFIER:default=de.b0x42.Prizm)";` (design D1). Touch no other build setting.
- [ ] 3.2 `Prizm/LocalConfig.xcconfig.template`: document the optional `PRIZM_BUNDLE_IDENTIFIER`, when it is needed (any team other than the maintainer's), and that it must be an identifier the developer owns. Leave it commented out, so the default applies.
- [ ] 3.3 `DEVELOPMENT.md`: explain `PRIZM_BUNDLE_IDENTIFIER` next to `DEVELOPMENT_TEAM`; correct the Personal Team statement; add `-allowProvisioningUpdates` to the `xcodebuild` build and test examples (design D5).
- [ ] 3.4 `CHANGELOG.md` under `## Unreleased`: fix signed local builds (missing bundle identifier, hard-coded team); note that users of v1.4.0–v1.5.0 may need to re-enable "Unlock with Touch ID" (design D4).

## 4. Verify (0.25 d)

- [ ] 4.1 Signed `build` and `test` (PrizmTests) with a non-maintainer team and its own `PRIZM_BUNDLE_IDENTIFIER` pass; 2.1 passes.
- [ ] 4.2 Unsigned build with the CI flags and the unchanged template: `CFBundleIdentifier` is `de.b0x42.Prizm`; both CI guards pass.
- [ ] 4.3 Signed UI test run (`PrizmUITests`) with a non-maintainer team. If the runner's identifier `de.b0x42.de.PrizmUITests` can't be registered, record it and decide whether to make it overridable like the app's (follow-up, not part of this fix unless trivial).
- [ ] 4.4 `git grep` finds no Team ID and no personal bundle identifier in committed files.
- [ ] 4.5 `openspec validate fix-app-signing-settings --type change --strict`.
- [ ] 4.6 At archive time: the main spec `openspec/specs/keychain-signing-config/spec.md` predates the `## Purpose` / `## Requirements` structure, so `openspec archive` refuses the delta until it is converted. Convert it in the archive commit (content unchanged), or archive with `--skip-specs` and merge by hand; the maintainer decides.
