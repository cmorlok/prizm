# Design

## Context

Sources: `$SRC` checkouts of 2026-10-23 (clients, ios, server) and Vaultwarden tag 1.37.4.

### What official clients send

- **TS clients (desktop, browser, web, CLI).** `fetch()` calls `applyPlatformHeaders` for **every**
  request, authenticated or not: `Bitwarden-Client-Name` (the client type, `"desktop"` for the
  desktop app), `Bitwarden-Client-Version` (the app version) and, when known,
  `Bitwarden-Package-Type` (`clients/libs/common/src/services/api.service.ts:1128-1138,1184-1194`).
  `Device-Type` is set on the token request (`:162-166`), on authenticated requests (`:1197-1213`)
  and in the generic header builder (`:1584-1586`). Unauthenticated API requests also send
  `Device-Identifier` "for flag targeting" (`:1599-1608`).
  The desktop's client type is `ClientType.Desktop` (`apps/desktop/src/platform/services/electron-platform-utils.service.ts:29-31`).
  The audit row A-07 says `Bitwarden-Client-Name` goes on authenticated requests only; the source
  shows it goes on all requests.
- **iOS.** `DefaultHeadersRequestHandler` sets `Bitwarden-Client-Name`, `Bitwarden-Client-Version`,
  `Device-Type` and `User-Agent` on every request
  (`ios/BitwardenKit/Core/Platform/Services/API/Handlers/DefaultHeadersRequestHandler.swift:29-35`).
- **Device name.** The desktop sends the lowercased device type without "desktop", i.e. `macos`
  (`electron-platform-utils.service.ts:24-27`; used as `DeviceRequest.name`,
  `libs/common/src/auth/models/request/identity-token/device.request.ts:16`).
- **`X-Client-Version`.** Not sent by any official client and not read by either server (no match
  in `server/src`, `vaultwarden/src`, `clients/libs`, `clients/apps/desktop/src`, `ios/`).

### Device type values

`server/src/Core/Enums/DeviceType.cs`: `WindowsDesktop = 6`, `MacOsDesktop = 7`,
`LinuxDesktop = 8`, `UnknownBrowser = 14`, `SDK = 21`, `MacOsCLI = 24` (lines 20-56).
`DeviceTypes.DesktopTypes` contains 6, 7 and 8, and `ToClientType` maps them to
`ClientType.Desktop` (`server/src/Core/Utilities/DeviceTypes.cs:14-18,53-60`).

### How the servers use these headers

- **Official server.** `CurrentContext` reads `Device-Type` into `DeviceType` and
  `Bitwarden-Client-Version` into `ClientVersion` (`server/src/Core/Context/CurrentContext.cs:65-74`).
  `DeviceType` feeds event logs, feature-flag context (`ServerContextBuilder.cs:22-23`) and
  `PartialCipherSupport`, which only treats `ClientType.Web` as able to receive partial ciphers
  (`server/src/Core/Vault/Authorization/PartialCipherSupport.cs:27-28`). Sending 7 therefore does
  not change the cipher shapes Prizm receives. `Bitwarden-Client-Name` is read in one place only,
  for the Duo redirect (`server/src/Core/Auth/Identity/TokenProviders/DuoUniversalTokenService.cs:194`).
- **Vaultwarden 1.37.4.** Reads `device-type` for event logging, defaulting to `UnknownBrowser`
  (`vaultwarden/src/auth.rs:620-625`). Reads `Bitwarden-Client-Version` as a semver
  (`auth.rs:1213-1231`). Does not read `Bitwarden-Client-Name`. The form field `deviceType` on the
  token request is required (`vaultwarden/src/api/identity.rs:77,95`).

### What `Bitwarden-Client-Version: 2024.12.0` does today (recorded, not changed)

| Server | Gate | Threshold | Effect on Prizm at 2024.12.0 |
|---|---|---|---|
| Vaultwarden 1.37.4 | SSH key items (type 5) in `/api/sync` | `>=2024.12.0` (`vaultwarden/src/api/core/ciphers.rs:129-138`) | SSH keys are sent. A missing or unparsable header hides them. |
| Official | SSH key items in sync | `SSHKeyCipherMinimumVersion = "2024.12.0"` (`server/src/Core/Constants.cs:35`; `SyncController.cs:192-196`) | SSH keys are sent. |
| Official | Bank account, driver's licence, passport (types 6–8) in sync | flag `PM32009_NewItemTypes` **and** `PM32009NewItemTypeMinimumVersion = "2026.2.0"` (`Constants.cs:38`; `SyncController.cs:198-205`) | Types 6–8 are withheld from Prizm. This protects Prizm, which cannot read them (03 S-14). |
| Official | Editing a login that has passkeys | `Fido2KeyCipherMinimumVersion = "2023.10.0"` (`Constants.cs:34`; `CiphersController.cs:1862-1873`) | Allowed. Prizm's edits must therefore preserve passkeys itself (`fix-cipher-edit-data-loss`). |
| Official | Login for accounts with v2 (COSE) encryption | `MinimumClientVersionForV2Encryption = "2025.11.0"` (`server/src/Core/KeyManagement/Constants.cs:5`; `ClientVersionValidator.cs:56-69`) | Login refused with "Please update your app to continue using Bitwarden". See `account-scope-and-unsupported-features`. |
| Official | Any password login | header required, else "No client version header found…" (`ClientVersionValidator.cs:29,46-51`) | Prizm sends it; must keep sending it on the token request. |

Raising the version would expose types 6–8 and change the v2 gate. That belongs to the change that
adds support for them.

### Prizm today

- `ClientHeaders` holds `clientId = "desktop"`, `clientVersion = "2024.12.0"`, `deviceType = "7"`,
  `userAgent = "Prizm/2024.12.0"` (`Data/Network/PrizmAPIClient.swift:388-394`).
- `baseRequest` sets `User-Agent`, `Accept`, `X-Client-Version`, `Bitwarden-Client-Version`
  (`:1024-1031`). Every server request starts from it.
- The token request sends `client_id=desktop`, `deviceType=7`, `deviceName=Prizm` as form fields
  (`:458-467`).
- `uploadAttachmentAzure` uses a plain `URLRequest` (`:766-781`), `downloadBlob` uses
  `session.data(from:)` (`:806-815`), `FaviconLoader` its own request (`FaviconLoader.swift:58`).
- `Config.clientName = "desktop"`, `Config.deviceType = 7` are unused (`App/Config.swift:26-29`).

## Goals / Non-Goals

**Goals**
- Prizm requests carry the headers the Constitution names, with the same values the official macOS
  desktop app uses.
- One definition of each value.
- No identification headers leak to hosts other than the configured server.

**Non-Goals:** see proposal.md.

## Decisions

### D1. `Device-Type: 7` (MacOsDesktop)

Prizm is a native macOS desktop app and already sends `deviceType=7` in the token request. Using
the same value in the header keeps event logs and device records consistent.

**Rejected:** `21` (SDK) or `24` (MacOsCLI). Both would misclassify Prizm on the server (as SDK or
CLI client type) and could change server behaviour tied to `ClientType.Desktop`. `14`
(UnknownBrowser) is what Vaultwarden assumes today when the header is missing, and is wrong.

### D2. `Bitwarden-Client-Name: desktop`

Matches `client_id=desktop` and the desktop app's `ClientType.Desktop`. Neither server needs it for
anything Prizm uses, but the Constitution requires it and it costs nothing.

### D3. Drop `X-Client-Version`; make `User-Agent` honest

`X-Client-Version` has no reader. `User-Agent` becomes
`Prizm/<CFBundleShortVersionString> (macOS <major.minor.patch>)`, built once at start-up. It is a
standard header, useful in server access logs, and must not carry the Bitwarden compatibility
version.

### D4. Keep `deviceName=Prizm` (deliberate difference, documented)

Official desktop sends `macos`. The device name appears in the web vault's device list and in the
"new device" email. `Prizm` lets a user tell this app apart from the official desktop app on the
same Mac, which helps when revoking a device. Neither server parses the name. The decision is
recorded in a code comment and in `client-identification` spec.

**Rejected:** `macos`, as official. It hides which app logged in.

### D5. Constants live in `Config`, headers only for the configured server

`Config` gets `clientName`, `deviceType`, `bitwardenClientVersion` and a comment with the table
above (why 2024.12.0, what it gates). `ClientHeaders` reads from `Config`. `baseRequest` is used only
for URLs under the configured base URL; a debug assertion checks the host. Azure, signed download
URLs and favicons keep their plain requests.

## Risks / Trade-offs

- **[Low] A proxy or WAF that filters on User-Agent.** → The new UA is still a simple product token.
  Rig check on Vaultwarden behind nginx (task 3.1).
- **[Low] Server behaviour keyed on `Device-Type`.** → Checked: on the official server it changes
  event logs, flag context and partial-cipher support (web only). Vaultwarden uses it for events only.

## Open Questions

1. Should Prizm send `Device-Identifier` on unauthenticated requests as the TS clients do? Not
   needed today; proposed as a non-goal.
