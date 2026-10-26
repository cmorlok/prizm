## Purpose

Store secrets in the data protection keychain without per-developer signing settings in the repo.

## Requirements

### Requirement: Data protection keychain access
The app SHALL store and retrieve all keychain items using the data protection keychain (`kSecUseDataProtectionKeychain: true`) scoped to the `$(AppIdentifierPrefix)com.prizm` access group, so that access is controlled by the app's entitlements rather than per-binary code-signature ACLs.

#### Scenario: New build reads keychain without prompt
- **WHEN** a developer builds and runs a new version of the app
- **THEN** no macOS keychain password dialog appears on startup or unlock

#### Scenario: Items scoped to access group
- **WHEN** a keychain item is written
- **THEN** it is stored with `kSecAttrAccessGroup` set to the resolved `$(AppIdentifierPrefix)com.prizm` value

### Requirement: Team ID excluded from repo
The git repository SHALL NOT contain the developer's Team ID or Apple ID in any committed file.

#### Scenario: Fresh clone builds without personal credentials
- **WHEN** a contributor clones the repo and opens the project
- **THEN** Xcode prompts them to set their own signing identity rather than using a committed Team ID

#### Scenario: Template guides setup
- **WHEN** a contributor needs to configure signing
- **THEN** a committed `LocalConfig.xcconfig.template` file tells them exactly what to copy and fill in

### Requirement: No duplicate keychain reads on unlock
The unlock flow SHALL read each keychain item at most once per unlock operation.

#### Scenario: Unlock reads email once
- **WHEN** the user unlocks the vault with their master password
- **THEN** `email`, `name`, and `serverEnvironment` are each read from keychain exactly once

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
CI SHALL fail when the built app has no bundle identifier or a bundle identifier other than `de.b0x42.Prizm`, or when the project file contains a non-empty `DEVELOPMENT_TEAM`.

#### Scenario: Bundle identifier removed again
- **GIVEN** a change that removes the app target's bundle identifier
- **WHEN** CI runs its unsigned build
- **THEN** the run SHALL fail with a message naming the missing `CFBundleIdentifier`

#### Scenario: Wrong default identifier
- **GIVEN** a change that alters the default identifier, or commits a personal `PRIZM_BUNDLE_IDENTIFIER` to the template
- **WHEN** CI runs its unsigned build with the unchanged template
- **THEN** the run SHALL fail with a message naming the actual and the expected identifier

#### Scenario: Team ID committed
- **GIVEN** a change that adds `DEVELOPMENT_TEAM = AB12CD34EF;` to the project file
- **WHEN** CI runs
- **THEN** the run SHALL fail with a message that the Team ID belongs in `LocalConfig.xcconfig`
