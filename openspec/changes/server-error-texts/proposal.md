# Proposal

## Why

**Criticality:** P2 (Medium: security, log hygiene)
**Findings:** follow-up of `harden-key-lifecycle-and-logging` (fix/009 review), decided 2026-10-26.

**Every HTTP error carries the raw response body into messages and public logs.**
`APIError.httpError(statusCode:body:)` describes itself as "Server error <code>: <body>"
(`Prizm/Data/Network/PrizmAPIClient.swift`, `APIError.errorDescription`).

- **Logs:** 62 log calls write an error with `privacy: .public`, as `error.localizedDescription`
  (56) or as `\(error)` (6). Public log entries are readable by any process on the Mac through
  `log stream` or Console.app, outside debug mode, and end up in sysdiagnose archives. A response
  body can contain account data, for example an e-mail address in a validation message, or a full
  HTML error page from a proxy.
- **UI:** the same text is shown to the user, for example "Server error 400: {"message":…,
  "validationErrors":…,"errorModel":…,"exceptionMessage":null,…}" instead of the server's message.

Official clients show the server's message (`ErrorResponse.getSingleMessage()`, clients
`libs/common/src/models/response/error.response.ts`) and never log response bodies.

### Origin of the current behaviour

- **Accidental.** The body was added to the description for debugging. `harden-key-lifecycle-and-logging`
  limited the token request log to an allow-list but left error descriptions alone (its review
  recorded this follow-up). `session-lifecycle` covers one visible case, the 429 at login.

## What Changes

- **Messages:** an HTTP error's description is the server's message, taken as the official clients
  take it: the first validation error, else `message`, else `errorModel.message` (identity
  responses); "Rate limit exceeded. Try again later." for 429; "Server error <code>." when the body
  has no usable message (empty, not JSON, HTML). Never the raw body.
- **Logs:** one helper, `ErrorLog.describe(_:)`, gives a log-safe description: HTTP status, URL error
  code or error type and case, never a message, body or user data. All 62 public error logs use it.
  The body stays available in the error value for code that needs it.

## Capabilities

### New Capabilities
- `server-error-texts`: what users see and what logs record when a request fails.

### Modified Capabilities
_None._

## Non-Goals

- Error texts of specific flows (login rate limit, new-device verification): `session-lifecycle`.
- Localising messages. Prizm has no localisation yet.
- Private (`privacy: .private`) or debug-only logs: they are redacted or off in release use.

## Impact

- **Domain:** `ErrorLog` helper and `LogSafeError` protocol (Foundation only).
- **Data:** `APIError` message parsing and log-safe description; log calls in Data.
- **Presentation:** log calls only; the shown texts change through `APIError.errorDescription`.
- **Security review:** yes (logging, §III/§V).

## Estimate

| Step | Scope | Estimate |
|---|---|---|
| 1 | Message parsing with fixtures from both servers | 0.25 d |
| 2 | `ErrorLog.describe` and the 62 log calls | 0.5 d |
| 3 | Review, CHANGELOG | 0.25 d |
| **Total** | | **1 d** |
