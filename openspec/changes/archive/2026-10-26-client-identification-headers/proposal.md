# Proposal

## Why

**Criticality:** P3 (Low)
**Findings:** A-07, A-19, A-20 (`01-auth-session.md`)

Prizm identifies itself to the server differently from official clients and from what its own
Constitution requires:

- **`Device-Type` and `Bitwarden-Client-Name` are never sent.** `baseRequest` sets `User-Agent`,
  `Accept`, `X-Client-Version` and `Bitwarden-Client-Version` only (`PrizmAPIClient.swift:1024-1031`).
  `Config.clientName` and `Config.deviceType` exist (`App/Config.swift:26-29`) but nothing reads
  them. The Constitution says "All API requests MUST include the minimum required headers (e.g.
  `Bitwarden-Client-Name`, `Bitwarden-Client-Version`, `Device-Type`)" (`CONSTITUTION.md:228-230`).
- **Effect for users:** server event logs record Prizm's API calls as "Unknown Browser" on
  Vaultwarden (`vaultwarden/src/auth.rs:620-625`) and with no device type on the official server
  (`server/src/Core/Context/CurrentContext.cs:65-69`). An admin reviewing events cannot tell a
  Prizm session from an unknown web client. Nothing breaks.
- **A nonstandard header and a misleading user agent.** `X-Client-Version` is read by neither
  server, nor sent by any official client. `User-Agent: Prizm/2024.12.0` reports the Bitwarden
  compatibility version as if it were Prizm's own version (Prizm is 1.5.0, `project.pbxproj:1203`).

### Origin of the current behaviour

Accidental. The header set dates from the first API client. The doc comment states a wrong
premise: "`X-Client-Version: "2024.12.0"` (version string, required by upstream Bitwarden)"
(`PrizmAPIClient.swift:362`). No server or official client uses that header (search of `server/src`,
`vaultwarden/src`, `clients/libs`, `clients/apps/desktop/src` and `ios/` finds none). `deviceName=Prizm`
(`PrizmAPIClient.swift:466`) has no design note either.

## What Changes

- Every request to the configured server (API and identity) sends:
  - `Device-Type: 7` (MacOsDesktop)
  - `Bitwarden-Client-Name: desktop`
  - `Bitwarden-Client-Version: 2024.12.0` (unchanged value)
- `X-Client-Version` is no longer sent.
- `User-Agent` becomes `Prizm/<app version> (macOS <OS version>)`, from the bundle, so it no longer
  pretends to be a Bitwarden version.
- The header values move into `Config` (one place, as the Constitution asks: "document the tested
  version in `Config.swift`", `CONSTITUTION.md:231-232`). The form fields `client_id` and
  `deviceType` read the same constants.
- Requests to other hosts (Azure blob upload, signed download URLs, favicons) get none of these
  headers.
- `deviceName=Prizm` stays, as a documented deliberate difference (D4).

## Capabilities

### New Capabilities
- `client-identification`: the identification headers and device fields Prizm sends to the server.

### Modified Capabilities
_None._

## Non-Goals

- **Changing `Bitwarden-Client-Version`.** The value gates server behaviour (see design.md,
  Context). Raising it needs its own change after the features it unlocks are supported.
- `Device-Identifier` on unauthenticated API requests and `Bitwarden-Package-Type`. Official
  clients send them for feature-flag targeting and telemetry; Prizm uses neither.
- Registering a client identifier with Bitwarden, Inc. Only needed for bitwarden.com
  (`CONSTITUTION.md:233-235`), which Prizm does not support.

## Dependencies

- **Soft:** `session-lifecycle`. Its D1 introduces one authenticated request path; this change adds
  the headers in the shared `baseRequest`, which both paths use. Whichever lands second rebases.
- None hard.

## Impact

- **Data:** `Data/Network/PrizmAPIClient.swift` (`ClientHeaders`, `baseRequest`, `identityToken`
  form fields, doc comment).
- **App:** `App/Config.swift` (constants and the documented compatibility version).
- **Domain / Presentation:** none.
- **No new dependencies.**
- **Security review:** no. No keys, tokens or crypto change. The review in `session-lifecycle`
  covers the request path.

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Header tests for API, identity and third-party requests | 0.25 d |
| 2 | `Config` constants, `baseRequest`, user agent, drop `X-Client-Version` | 0.25 d |
| 3 | Rig check (Vaultwarden event log), docs, CHANGELOG | 0.25 d |
| **Total** | | **0.75 d** |
