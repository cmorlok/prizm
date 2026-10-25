# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Header tests (0.25 d)

- [ ] 1.1 Failing test (mock `URLProtocol`): prelogin, token, refresh, sync, cipher update and attachment-metadata requests each carry `Device-Type: 7`, `Bitwarden-Client-Name: desktop`, `Bitwarden-Client-Version: 2024.12.0`, and no `X-Client-Version`.
- [ ] 1.2 Failing test: `User-Agent` equals `Prizm/<CFBundleShortVersionString> (macOS <x.y.z>)` built from injected values.
- [ ] 1.3 Test (should already pass, guards against regressions): Azure upload, `downloadBlob` and favicon requests carry none of the identification headers and no `Authorization`.

## 2. Implementation (0.25 d)

- [ ] 2.1 Move `clientName`, `deviceType` and `bitwardenClientVersion` into `App/Config.swift`, with a comment that lists what 2024.12.0 gates on each server (design.md, Context table) per the Constitution's "document the tested version in `Config.swift`".
- [ ] 2.2 `ClientHeaders` and the token form fields read from `Config`. `baseRequest` adds `Device-Type` and `Bitwarden-Client-Name`, drops `X-Client-Version`, builds the new `User-Agent`. Add a debug assertion that `baseRequest` is only used for URLs under the configured base URL.
- [ ] 2.3 Fix the doc comment on `PrizmAPIClientImpl` (remove the `X-Client-Version` "required by upstream Bitwarden" claim) and add the D4 comment on `deviceName`.

## 3. Release (0.25 d)

- [ ] 3.1 Rig check on Vaultwarden 1.37.4 behind nginx: login, sync, edit an org item; confirm the org event log shows macOS desktop. Confirm SSH key items still sync.
- [ ] 3.2 No security review needed (no keys, tokens or crypto touched); note this in the PR.
- [ ] 3.3 CHANGELOG "Changed": Prizm now identifies itself to the server as a macOS desktop client, and its user agent shows the Prizm version.
- [ ] 3.4 `openspec validate client-identification-headers --type change --strict`.
