# Development Guide

## Prerequisites

- **Xcode 26** (beta or release) — the project requires the macOS 26 SDK
- **macOS 26** or later on the development machine
- An Apple ID (free) for local builds; a paid Apple Developer account for release signing

No package managers required. Dependencies are vendored under `LocalPackages/`.

## Cloning and Setup

```bash
git clone https://github.com/b0x42/prizm.git
cd prizm
```

### LocalConfig.xcconfig (required before building)

The project requires a per-developer signing config file that is not committed to the repository:

```bash
cp Prizm/LocalConfig.xcconfig.template Prizm/LocalConfig.xcconfig
```

Open `Prizm/LocalConfig.xcconfig` and fill in `DEVELOPMENT_TEAM`:

```
DEVELOPMENT_TEAM = AB12CD34EF
```

**Where to find your Team ID:**

- Xcode → Settings → Accounts → select your Apple ID → the Team ID is in parentheses
- Or: [developer.apple.com](https://developer.apple.com) → Account → Membership → Team ID

**Bundle identifier.** The app's default bundle identifier, `de.b0x42.Prizm`, is registered to the
maintainer's team, and Apple allows each identifier in only one team. If you sign with any other
team, also set an identifier you own, for example a reverse domain name of yours:

```
PRIZM_BUNDLE_IDENTIFIER = com.example.Prizm
```

Without it, signing fails with "The app identifier "de.b0x42.Prizm" cannot be registered to your
development team because it is not available."

A free Apple ID ("Personal Team") is enough to build and run on your own Mac, as long as you set
your own bundle identifier. You do not need a paid account.

> **The build will fail without this file.** `LocalConfig.xcconfig` is git-ignored so your Team ID and bundle identifier never appear in the repository.

## Building

Open the project in Xcode:

```bash
open "Prizm/Prizm.xcodeproj"
```

Then press `⌘R` to build and run. No additional steps needed.

Or build from the command line:

```bash
xcodebuild -project "Prizm/Prizm.xcodeproj" \
           -scheme "Prizm" \
           -configuration Debug \
           -allowProvisioningUpdates \
           build
```

`-allowProvisioningUpdates` lets automatic signing create your development provisioning profile
from the command line, as Xcode does on its own. It needs your Apple ID in Xcode → Settings →
Accounts.

## Running Tests

Press `⌘U` in Xcode, or from the command line:

```bash
xcodebuild test \
  -project "Prizm/Prizm.xcodeproj" \
  -scheme "Prizm" \
  -destination "platform=macOS" \
  -allowProvisioningUpdates
```

All tests must pass before merging to `main`. The CI workflow enforces this on every push and pull request.

### UI tests

The `Prizm` scheme runs the unit tests only. The UI journeys in `Prizm/UITests/` have their own
scheme, `PrizmUITests`, and CI does not run them:

```bash
xcodebuild test \
  -project "Prizm/Prizm.xcodeproj" \
  -scheme "PrizmUITests" \
  -destination "platform=macOS" \
  -allowProvisioningUpdates
```

- **They take over the screen.** A full run takes about 10–15 minutes and moves the mouse and types
  into the app. Don't use the Mac meanwhile; a click elsewhere can make a test fail.
- **They don't touch your data.** The tests start a Debug build in one of three test states, set
  with launch arguments that exist only in Debug builds (`App/UITestFixtures.swift`):
  `--ui-test-vault` (a seeded vault, unlocked, no server), `--ui-test-locked` (the unlock screen for
  a fixture account) and `--ui-test-signed-out` (the login screen). In every test state the app
  uses an in-memory keychain, so your stored Prizm login is never read or deleted. The password
  generator options you change in a test run are kept, though.
- **Skipped tests say why.** Saving, downloading attachments and Touch ID need a test backend or
  simulated Touch ID that does not exist yet; those steps are reported as skipped with the reason.
- **Journeys with a real account** (sign in, unlock) run only when you pass an account. `xcodebuild`
  forwards variables to the test runner only with the `TEST_RUNNER_` prefix:

  ```bash
  TEST_RUNNER_BW_TEST_SERVER_URL=https://vault.example.com \
  TEST_RUNNER_BW_TEST_EMAIL=you@example.com \
  TEST_RUNNER_BW_TEST_PASSWORD='…' \
  xcodebuild test -project "Prizm/Prizm.xcodeproj" -scheme "PrizmUITests" \
    -destination "platform=macOS" -allowProvisioningUpdates
  ```

  Use a test account, not your own vault. The two-factor journey needs a second account with
  two-step login enabled, in `TEST_RUNNER_BW_TEST_2FA_EMAIL` and `TEST_RUNNER_BW_TEST_2FA_PASSWORD`.
- **No system-wide shortcuts.** A UI test must never send key combinations that macOS handles
  itself: ⌘⇧Q logs you out of macOS, ⌃⌘Q locks the screen.

## Architecture

Three-layer Clean Architecture with strict dependency direction:

```
App/              @main entry point, DI container, root state machine
Domain/           Protocols, entities, use cases — import Foundation only
Data/             Crypto, network, keychain, mappers, repository implementations
Presentation/     SwiftUI views and view models — import SwiftUI only
```

**Rules:**
- `Domain` has zero dependencies on `Data` or `Presentation`
- `Presentation` never imports `Data`, `CommonCrypto`, `CryptoKit`, or `Argon2Swift`
- `Data` is the only layer that imports crypto frameworks
- All cross-layer communication happens through protocols defined in `Domain`

See `CONSTITUTION.md` for the full set of non-negotiable architectural constraints.

## openspec Workflow

Feature changes are tracked in `openspec/changes/<name>/`. Each change has three artifacts:

- `proposal.md` — what and why
- `design.md` — how (data model, API surface, decision log)
- `tasks.md` — numbered implementation steps

Changes are implemented task-by-task (TDD: write failing test → implement → refactor) and archived to `openspec/changes/archive/` when complete.

To explore or propose a change, use the `/opsx:` skills in Claude Code.

## Contributing

1. Open an issue describing what you want to build or fix
2. For non-trivial changes, create an openspec change with proposal and design before writing code
3. Implement with TDD — failing test first, then implementation
4. All tests must pass; no regressions
5. All icon-only buttons must have an `accessibilityLabel`; see `ACCESSIBILITY.md` for conformance details
6. Open a pull request with a clear description

## GitHub Secrets (Release Signing)

The release workflow (`.github/workflows/release.yml`) requires the following secrets configured in GitHub Settings → Secrets and variables → Actions:

| Secret | Description | How to obtain |
|---|---|---|
| `CERT_P12` | Developer ID Application certificate, base64-encoded `.p12` file | Xcode → Settings → Accounts → Manage Certificates → export Developer ID Application cert |
| `CERT_PASSWORD` | Password used when exporting the `.p12` | Set during export |
| `NOTARYTOOL_KEY` | App Store Connect API key (`.p8` file), base64-encoded | [App Store Connect](https://appstoreconnect.apple.com) → Users and Access → Integrations → App Store Connect API → generate key with Developer role |
| `NOTARYTOOL_KEY_ID` | App Store Connect API key ID (10-character string) | Shown next to the key in App Store Connect |
| `NOTARYTOOL_ISSUER_ID` | App Store Connect Issuer ID (UUID) | Shown at the top of the API Keys page in App Store Connect |
| `TEAM_ID` | Your 10-character Apple Developer Team ID | developer.apple.com → Account → Membership |

Base64-encode a file for use as a secret:

```bash
base64 -i YourCert.p12 | pbcopy   # copies to clipboard
```

Without these secrets, the signing and notarization steps will fail. For local development, you only need `LocalConfig.xcconfig` — no secrets required.
