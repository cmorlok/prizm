# Design

## Context

**Official clients.** Sources at HEAD 2026-10-23.
- TS clients: `PasswordPreloginApiService.getPreloginData` sends `POST /accounts/prelogin/password`
  to `env.getIdentityUrl()` with body `{ email }`
  (`clients/libs/common/src/auth/password-prelogin/password-prelogin-api.service.ts:15-26`,
  request model `password-prelogin.request.ts`).
- SDK: `LoginClient::get_password_prelogin` uses the identity client
  (`sdk-internal/crates/bitwarden-auth/src/login/login_via_password/password_prelogin.rs:36-52`).
  The generated path is `{identity}/accounts/prelogin/password`
  (`sdk-internal/crates/bitwarden-api-identity/src/apis/accounts_api.rs:110`). The SDK tests mock
  exactly `/identity/accounts/prelogin/password` (`password_prelogin.rs:116`).

**Official server.** Sources at HEAD 2026-10-23 and at tags.
- HEAD: prelogin exists only in Identity: `server/src/Identity/Controllers/AccountsController.cs:216-235`.
  `POST prelogin` is `[Obsolete(... "Use prelogin/password instead. This endpoint has no EOL at the
  time of writing.")]` (`:216-218`); `POST prelogin/password` is the current route. Both call
  `MakePasswordPreloginCall`.
- `POST /identity/accounts/prelogin` exists on every tag checked: v2023.10.0
  (`src/Identity/Controllers/AccountsController.cs:60`), v2024.1.0 (`:72`), v2024.6.0 to HEAD.
- `POST /identity/accounts/prelogin/password` exists from v2025.12.0.
- The API service had `POST /api/accounts/prelogin` up to at least v2024.6.0, marked
  `[Obsolete("TDL-136 Moved to Identity (2022-01-12 cloud, 2022-09-19 self-hosted) …")]`
  (v2024.1.0: `src/Api/Auth/Controllers/AccountsController.cs:134-137`). It is absent in v2025.1.0.

**Vaultwarden 1.37.4** (tag checked out at `$SRC/vaultwarden`).
- Routes `POST /identity/accounts/prelogin` and `POST /identity/accounts/prelogin/password`
  (`src/api/identity.rs:1020-1028`), both calling `accounts::prelogin`.
- `POST /api/accounts/prelogin` is gone: commit `1f99d9d` (contained in tag 1.37.4).
- Response (`src/api/core/accounts.rs:1400-1425`): `kdf`, `kdfIterations`, `kdfMemory`,
  `kdfParallelism`, `kdfSettings { iterations, kdfType, memory, parallelism }`, `salt: null`.
  Request `{ "email" }` (`accounts.rs:1377-1381`); the email is trimmed and lowercased server side
  (`:1405`).

**Vaultwarden 1.37.3** (`$SRC/vaultwarden-1.37.3`): still has `/api/accounts/prelogin`
(`src/api/core/accounts.rs:60`) and already has both identity routes (`src/api/identity.rs:1058-1066`).

**Older Vaultwarden tags** (`git show <tag>:src/api/identity.rs`):
- `POST /identity/accounts/prelogin` exists in 1.32.0 (`:677`), 1.34.0 (`:730`) and 1.35.4 (`:930`).
- `POST /identity/accounts/prelogin/password` first appears in 1.36.0 (`:1014`).

**Which route each server serves**

| Server | `/api/accounts/prelogin` (Prizm today) | `/identity/accounts/prelogin` | `/identity/accounts/prelogin/password` | Prizm after this change |
|---|---|---|---|---|
| Vaultwarden 1.32.0–1.35.x | yes | yes | no | legacy fallback (D2) |
| Vaultwarden 1.36.0–1.37.3 | yes | yes | yes | primary route |
| Vaultwarden 1.37.4 | no (`1f99d9d`) | yes | yes | primary route |
| Bitwarden v2023.10.0–v2024.6.0 (tags checked) | yes (obsolete) | yes | no | legacy fallback (D2) |
| Bitwarden v2025.1.0–v2025.11.x | no | yes | no | legacy fallback (D2) |
| Bitwarden ≥ v2025.12.0 | no | yes (obsolete, no EOL) | yes | primary route |

Every server on which login works today serves one of the two identity routes. So the change keeps
all of them (Vaultwarden 1.32+, Bitwarden servers with the identity route) and adds Vaultwarden
1.37.4 and Bitwarden v2025.1.0 and later.

**Prizm today.**
- `PrizmAPIClientImpl.preLogin` builds `base.appendingPathComponent("api/accounts/prelogin")`
  (`Prizm/Data/Network/PrizmAPIClient.swift:418-438`) and decodes `PreLoginResponse`
  (`:211-230`: flat fields, `kdf` and `kdfIterations` required).
- The token endpoint already uses the identity service: `identity/connect/token` (`:451`, `:995`).
- Tests stub `preLogin` in `PrizmTests/Mocks/MockPrizmAPIClient.swift:58`. No test checks the URL.

## Goals / Non-Goals

**Goals**
- Login works on Vaultwarden 1.37.4 and on a current Bitwarden self-hosted server.
- Login keeps working on every server where it works today (Vaultwarden 1.32+).
- The smallest possible change, so it can ship as a patch on its own.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Primary route: `{base}/identity/accounts/prelogin/password`

It is what the TS clients and the SDK call, and the only route the official server does not mark
obsolete. Vaultwarden 1.36.0+ and Bitwarden v2025.12.0+ serve it. The identity URL is derived from
the base URL the same way as for `/connect/token`.

### D2. Legacy fallback: `{base}/identity/accounts/prelogin` in `LegacyPreloginEndpoint`

Per the compatibility rule (`openspec/changes/FIX-ORDER.md`), Prizm must not drop servers that work
today. Vaultwarden 1.32.0–1.35.x and Bitwarden servers before v2025.12.0 do not serve the
`/password` route, but all of them serve `/identity/accounts/prelogin` (Context).

- `PrizmAPIClientImpl.preLogin` calls the primary route. Only when it answers **404 or 405** does it
  call `LegacyPreloginEndpoint` (new file `Prizm/Data/Network/Legacy/LegacyPreloginEndpoint.swift`).
- The adapter sends the same body to `{base}/identity/accounts/prelogin` and decodes the same
  `PreLoginResponse`. It logs at `.info` that the legacy route was used (no email).
- It carries the marker
  `// LEGACY(Vaultwarden < 1.36.0, Bitwarden server < v2025.12.0): remove when those versions are no longer supported`.
- Any other failure of the primary route (network error, 400, 5xx, decode error) is surfaced as
  today. It does not trigger the fallback, so a broken server is not hidden.
- No caching of which route worked. An older server costs one extra request per login; that is
  cheaper than state that must be invalidated when the server is upgraded.

**Not used:** `/api/accounts/prelogin`. Every server that serves it also serves
`/identity/accounts/prelogin`, so a second legacy path would add nothing.

**Rejected:** no fallback, raise the README minimum. That breaks login on Vaultwarden 1.32–1.35,
including 1.35.4, the version README names as tested.

### D3. Response decoding unchanged

Both routes on both servers still send the flat `kdf*` fields, so `PreLoginResponse` keeps working.
Switching to `kdfSettings` and `salt` is a behaviour change with its own tests and belongs to
`fix-kdf-derivation-and-validation`.

## Risks / Trade-offs

- **[Low] A proxy or server answers 404 for the new route for another reason.** → The fallback then
  asks the legacy identity route, which returns the same data. No security impact: both routes are
  on the same host and return the same public KDF settings.
- **[Low] Reverse proxies** that only forward `/api` and not `/identity` would now break prelogin.
  They already break `/identity/connect/token`, so login never worked behind them.
- **[Low] The official server removes `/identity/accounts/prelogin`.** It has no EOL today. Only
  servers that also serve the primary route could remove it, so the fallback is never needed there.

## Open Questions

_None._ The first Vaultwarden release with the `/password` route (1.36.0) was found from the tags.
