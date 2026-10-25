# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). This change has
no dependencies. Ship it as a patch release before any other change that needs a working login.

## 1. Failing tests (0.25 d)

- [ ] 1.1 Failing test: with a `URLProtocol` stub, `preLogin(email:)` sends `POST {base}/identity/accounts/prelogin/password` with JSON body `{"email": …}` and `Content-Type: application/json`. Nothing is sent to `/api/accounts/prelogin`.
- [ ] 1.2 Failing test: the primary route answers 200. Exactly one request is sent, and nothing goes to `/identity/accounts/prelogin` (the legacy adapter is not used).
- [ ] 1.3 Failing tests: the primary route answers 404, and in a second case 405. A second request goes to `POST {base}/identity/accounts/prelogin` with the same body, and its response is returned.
- [ ] 1.4 Failing tests: the primary route answers 400, 500, a network error, and 200 with an undecodable body. Each is surfaced as today and no second request is sent.
- [ ] 1.5 Failing test: the Vaultwarden 1.37.4 response fixture (flat fields plus `kdfSettings` and `"salt": null`) and a Vaultwarden 1.35.4 fixture (flat fields only) decode into the same `KdfParams` as today.

## 2. Switch the path, add the legacy adapter (0.25 d)

- [ ] 2.1 Change the path in `PrizmAPIClientImpl.preLogin` (design.md D1).
- [ ] 2.2 Add `Prizm/Data/Network/Legacy/LegacyPreloginEndpoint.swift` (design.md D2) with the marker `// LEGACY(Vaultwarden < 1.36.0, Bitwarden server < v2025.12.0): remove when those versions are no longer supported`. `preLogin` calls it only on 404 or 405. Log at `.info` that the legacy route was used, without the email.
- [ ] 2.3 Update the doc comments in `PrizmAPIClient.swift` (protocol and `PreLoginResponse`), `AuthRepositoryImpl.swift:10`, `Domain/Repositories/AuthRepository.swift:22` and `Domain/Entities/KdfParams.swift:4`. Tasks 1.1–1.5 pass.

## 3. Release (0.25–0.5 d)

- [ ] 3.1 Interop check on the rig: sign in on Vaultwarden 1.37.4 with a PBKDF2 account. Then sign out and sign in again.
- [ ] 3.2 Interop check of the fallback: sign in on Vaultwarden 1.35.4 (a throw-away container next to the rig). If that is not possible, record that tasks 1.3 and 1.5 cover it.
- [ ] 3.3 README: update "Tested against Vaultwarden …" to the versions checked in 3.1 and 3.2.
- [ ] 3.4 CHANGELOG "Fixed": signing in works again on Vaultwarden 1.37.4 and on current Bitwarden self-hosted servers (prelogin now uses the identity service). Older servers keep working.
- [ ] 3.5 Add the `LegacyPreloginEndpoint` row to the "Legacy adapters" table in `openspec/changes/FIX-ORDER.md` if it is not there.
- [ ] 3.6 `openspec validate fix-prelogin-identity-endpoint --type change --strict`.
