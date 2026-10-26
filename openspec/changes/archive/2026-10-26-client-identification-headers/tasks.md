# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Header tests (0.25 d)

- [x] 1.1 Failing test (mock `URLProtocol`): prelogin, token, refresh, sync, cipher update and attachment-metadata requests each carry `Device-Type: 7`, `Bitwarden-Client-Name: desktop`, `Bitwarden-Client-Version: 2024.12.0`, and no `X-Client-Version`.
- [x] 1.2 Failing test: `User-Agent` equals `Prizm/<CFBundleShortVersionString> (macOS <x.y.z>)` built from injected values.
- [x] 1.3 Test (should already pass, guards against regressions): Azure upload, `downloadBlob` and favicon requests carry none of the identification headers and no `Authorization`.

## 2. Implementation (0.25 d)

- [x] 2.1 Move `clientName`, `deviceType` and `bitwardenClientVersion` into `App/Config.swift`, with a comment that lists what 2024.12.0 gates on each server (design.md, Context table) per the Constitution's "document the tested version in `Config.swift`".
- [x] 2.2 `ClientHeaders` and the token form fields read from `Config`. `baseRequest` adds `Device-Type` and `Bitwarden-Client-Name`, drops `X-Client-Version`, builds the new `User-Agent`. Add a debug assertion that `baseRequest` is only used for URLs under the configured base URL.
- [x] 2.3 Fix the doc comment on `PrizmAPIClientImpl` (remove the `X-Client-Version` "required by upstream Bitwarden" claim) and add the D4 comment on `deviceName`.

## 3. Release (0.25 d)

- [ ] 3.1 Rig check on Vaultwarden 1.37.4 behind nginx: login, sync, edit an org item; confirm the org event log shows macOS desktop. Confirm SSH key items still sync.
- [x] 3.2 No security review needed (no keys, tokens or crypto touched); note this in the PR.
- [x] 3.3 CHANGELOG "Changed": Prizm now identifies itself to the server as a macOS desktop client, and its user agent shows the Prizm version.
- [x] 3.4 `openspec validate client-identification-headers --type change --strict`.

## Results (2026-10-26)

- Header names checked: Vaultwarden 1.37.4 reads `device-type` (`src/auth.rs:623`) and
  `Bitwarden-Client-Version` (`:1222`); the official server reads `Device-Type` and
  `Bitwarden-Client-Version` (`CurrentContext.cs:65,71`); the TS clients send `Device-Type` and
  `Bitwarden-Client-Name` (`api.service.ts`).
- `ClientIdentificationHeaderTests`: prelogin, token, refresh, sync and attachment-metadata
  requests are identified and carry no `X-Client-Version`; blob download and Azure upload carry no
  identification and no `Authorization`; the user agent from injected values. Favicons use their
  own loader with plain requests (not tested here). The cipher update goes through the same
  `baseRequest` and is not tested separately.
- `Config` is `nonisolated` (it is read from the API client actor).
- Review: no blocking issue. The `assert` in `baseRequest` cannot fire (every caller builds its URL
  from the base URL). Fixed: the user-agent assertion compares the exact value; `deviceName=Prizm`
  is checked; the Device-Type comment and CHANGELOG now say the "unknown browser" effect is
  Vaultwarden's (the official server reads the device type from the token claim). Note for future
  Duo work: the official server reads `Bitwarden-Client-Name` to pick the Duo redirect.
- **Verified on the Mac (2026-10-26):** all 679 unit tests pass on this branch; the full UI suite passes on the top of the series (`fix/017`).
- Open: 3.1 needs the rig (event log shows macOS desktop; SSH key items still sync).

