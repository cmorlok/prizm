# Proposal

## Why

**Criticality:** P0 (Critical)
**Findings:** A-03 (`01-auth-session.md`)

Nobody can sign in to Prizm on Vaultwarden 1.37.4. Login fails at step 1, before the password is
checked.

Prizm asks the server for the account's KDF settings with `POST {base}/api/accounts/prelogin`
(`Prizm/Data/Network/PrizmAPIClient.swift:420`). That route was an alias in the API service:
- Vaultwarden 1.37.4 removed it in commit `1f99d9d` ("Remove legacy API endpoints … Legacy POST
  /identity/accounts/register and POST /api/accounts/prelogin"). The request now gets HTTP 404.
- The official Bitwarden server had it up to at least v2024.6.0, marked
  `[Obsolete("TDL-136 Moved to Identity …")]`, and no longer has it in v2025.1.0. So login on a
  current Bitwarden self-hosted server fails the same way.

Official clients call `POST {identity}/accounts/prelogin/password`, with no fallback
(`clients/libs/common/src/auth/password-prelogin/password-prelogin-api.service.ts:19`). It exists
from Vaultwarden 1.36.0 and Bitwarden v2025.12.0. `POST {identity}/accounts/prelogin` exists on
every version checked (Vaultwarden 1.32.0–1.37.4, Bitwarden v2023.10.0 to HEAD).

Users see a generic server error on the login screen and cannot get past it. Existing sessions
still unlock offline, because unlock does not call prelogin. The first sign-out, or a fresh
install, locks the user out.

### Origin of the current behaviour

**Accidental.** The path was added in `20f2aaa` (2026-03-16, "feat(auth): implement Phase 4 —
Account Login") with no design note. It worked because Vaultwarden kept the old API-service route.
README says "Tested against Vaultwarden 1.35.4" (`README.md:64`).

## What Changes

- Prelogin goes to `POST {base}/identity/accounts/prelogin/password`, the same endpoint and body
  (`{"email": …}`) as the official clients and the Bitwarden SDK.
- If that route answers 404 or 405, Prizm asks `POST {base}/identity/accounts/prelogin` instead,
  through a separate legacy adapter (`LegacyPreloginEndpoint`, design.md D2). It serves Vaultwarden
  < 1.36.0 and Bitwarden servers < v2025.12.0, and is removed when those are no longer supported.
- No server where login works today loses it (Vaultwarden 1.32+). Vaultwarden 1.37.4 and Bitwarden
  servers from v2025.1.0 start working. See the version table in design.md, Context.
- Doc comments that name `/accounts/prelogin` are corrected.
- README "Tested against" names the Vaultwarden version this change is checked on.

The response is decoded as today (flat `kdf`, `kdfIterations`, `kdfMemory`, `kdfParallelism`).
Every server still sends these fields. Reading `kdfSettings` and `salt` is left to
`fix-kdf-derivation-and-validation`, so that this fix stays small and can ship on its own.

## Capabilities

### New Capabilities
- `prelogin-endpoint`: Prizm fetches KDF settings from the Identity service endpoint that current
  Bitwarden and Vaultwarden servers serve, with a legacy fallback for older servers.

### Modified Capabilities
_None._ Related existing spec: `openspec/specs/vault-browser-ui` (login flow). It does not name
the prelogin path and is not changed.

## Non-Goals

- Reading `kdfSettings` / `salt`, KDF minimums, Argon2id fixes: `fix-kdf-derivation-and-validation`.
- Separate identity URL overrides (`ServerURLOverrides`, A-15). The identity URL stays
  `{base}/identity`, as for `/connect/token` today.
- Better error messages on login failures (A-10): `session-lifecycle`.
- Calling `/api/accounts/prelogin` at all. Every server that has it also has the legacy identity
  route (design.md D2).

## Dependencies

None. Ship first: every other login-related change needs a working login to be tested.
`fix-kdf-derivation-and-validation` builds on this change (soft: same function).

## Impact

- **Data:** `PrizmAPIClientImpl.preLogin` (path and 404/405 fallback), new
  `Data/Network/Legacy/LegacyPreloginEndpoint.swift`, doc comments in `PrizmAPIClient.swift`,
  `AuthRepositoryImpl.swift:10`, `AuthRepository.swift:22`, `KdfParams.swift:4`.
- **Domain / Presentation:** none (doc comments only in Domain).
- **Docs:** README "Tested against" line; CHANGELOG.
- **No new dependencies.**
- **Security review:** no. The request carries only the email, as before, and goes to the same
  host over HTTPS.

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Failing tests: primary URL, fallback on 404/405, no fallback otherwise | 0.25 d |
| 2 | Path change, `LegacyPreloginEndpoint`, doc comments | 0.25 d |
| 3 | Login on Vaultwarden 1.37.4 (rig) and on an older version, README, CHANGELOG | 0.25–0.5 d |
| **Total** | | **0.75–1 d** |
