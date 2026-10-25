# Spec Delta

## ADDED Requirements

### Requirement: App bundle identifier is always set and overridable
The app target SHALL always have a non-empty bundle identifier. It SHALL be `de.b0x42.Prizm` unless the git-ignored `LocalConfig.xcconfig` sets `PRIZM_BUNDLE_IDENTIFIER`, in which case that value SHALL be used. No committed file SHALL contain a contributor's personal bundle identifier.

#### Scenario: CI and release builds use the default identifier
- **GIVEN** `LocalConfig.xcconfig` copied unchanged from `LocalConfig.xcconfig.template`
- **WHEN** the app is built without code signing, as CI and the release workflow do
- **THEN** the built app's `Info.plist` SHALL contain `CFBundleIdentifier` = `de.b0x42.Prizm`

#### Scenario: Contributor builds with their own team and identifier
- **GIVEN** a contributor whose `LocalConfig.xcconfig` sets `DEVELOPMENT_TEAM` to their own team and `PRIZM_BUNDLE_IDENTIFIER` to an identifier they own
- **WHEN** they build and test the app with signing, in Xcode or with `xcodebuild -allowProvisioningUpdates`
- **THEN** the build SHALL be signed with their team
- **AND** the app SHALL have their bundle identifier

#### Scenario: Existing local config without the new variable
- **GIVEN** a `LocalConfig.xcconfig` created from the old template, without `PRIZM_BUNDLE_IDENTIFIER`
- **WHEN** the app is built
- **THEN** the bundle identifier SHALL be `de.b0x42.Prizm`

### Requirement: Signing settings come only from the local config
The app target SHALL NOT set `DEVELOPMENT_TEAM` in the project file. The team SHALL come from `LocalConfig.xcconfig`, so that the existing requirement "Team ID excluded from repo" holds.

#### Scenario: Team set in the local config is used
- **GIVEN** `LocalConfig.xcconfig` sets `DEVELOPMENT_TEAM` to a contributor's team
- **WHEN** the app is built with signing
- **THEN** it SHALL be signed with that team, not with any team from the project file

### Requirement: CI rejects broken signing settings
CI SHALL fail when the built app has no bundle identifier, or when the project file contains a non-empty `DEVELOPMENT_TEAM`.

#### Scenario: Bundle identifier removed again
- **GIVEN** a change that removes the app target's bundle identifier
- **WHEN** CI runs its unsigned build
- **THEN** the run SHALL fail with a message naming the missing `CFBundleIdentifier`

#### Scenario: Team ID committed
- **GIVEN** a change that adds `DEVELOPMENT_TEAM = AB12CD34EF;` to the project file
- **WHEN** CI runs
- **THEN** the run SHALL fail with a message that the Team ID belongs in `LocalConfig.xcconfig`
