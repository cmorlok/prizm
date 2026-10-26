# Design

## Context

**Server error bodies.**
- Vaultwarden 1.37.4 (`src/error.rs`, `ApiErrorResponse`): `message`, `validationErrors: {"": [message]}`,
  `errorModel: {message, object}`, `error`, `error_description`, `exceptionMessage: null`, `object`.
  The compact form has `message` and `validationErrors: null`.
- Bitwarden server: `ErrorResponseModel` (`Message`, `ValidationErrors`, `ExceptionMessage`, …),
  PascalCase or camelCase depending on the endpoint; identity errors carry
  `error`, `error_description` and `ErrorModel { Message }`.
- Official clients (`error.response.ts`): 429 → "Rate limit exceeded. Try again later."; for identity
  responses `ErrorModel.Message`, else `Message`; `getSingleMessage()` returns the first validation
  error if any, else the message. Property lookup ignores the case of the first letter.

**Prizm today.** `APIError.errorDescription` returns "Server error <code>: <body>". Callers read only
the status code from the error (`SyncRepositoryImpl`, `VaultRepositoryImpl`, `AttachmentRepositoryImpl`,
`LegacyPreloginEndpoint`); none parses the body. `EmptyTrashUseCaseImpl` already has a private
log-safe `describe` (fix/008).

## Decisions

### D1. The message is the server's message, never the body

`APIError.serverMessage` parses the body as JSON and returns, in this order: the first non-empty
string in `validationErrors`/`ValidationErrors` (keys in sorted order, so the result is stable), else
`message`/`Message`, else `errorModel.message`/`ErrorModel.Message`. A 429 gives the official rate
limit text. Empty strings are skipped. Anything else (not JSON, HTML, no message) gives no server
message, and the description is "Server error <code>.". The message is cut at 300 characters.

**Deviation:** with several validation keys, the official clients take the first key in the
JSON's order. `JSONSerialization` keeps no order, so Prizm takes the first in sorted order. Only
Bitwarden responses with several invalid fields are affected; Vaultwarden sends one key (`""`).

Identity and API responses use the same order. On Vaultwarden all three fields carry the same text;
on Bitwarden identity errors, `ErrorModel.Message` is the only readable one.

### D2. One log-safe description for every error

`ErrorLog.describe(_ error: Error) -> String` (Domain, Foundation only):
- an error that conforms to `LogSafeError` gives its `logDescription` (`APIError`: "HTTP 404",
  "decodingFailed", "baseURLNotSet")
- `URLError`: "URLError <code>"
- anything else: `"<domain> <code>"` of its `NSError` bridge, which for a Swift enum is the type
  name and a per-case code, with no associated values. `KeychainError` conforms to `LogSafeError`
  to keep its OSStatus.

`ErrorLog`'s conformances are `nonisolated`: actors log through it, and a main-actor conformance
would fail the dynamic cast there.

Every log call that writes an error with `privacy: .public` uses it. Error messages in logs are
dropped on purpose: a message can quote user input or server text. The status, URL error code or
type and case are enough to find the failing path; the debug allow-list of fix/009 covers deeper
debugging.

**Rejected alternative:** keep `localizedDescription` but strip bodies from `APIError` only. Other
errors (`DecodingError` with key paths and values, `CocoaError` with file paths) can carry data too.

### D3. The body stays in the error value

`httpError(statusCode:body:)` keeps the body, so a later flow (for example `session-lifecycle`'s
new-device verification) can read it. It is never logged or shown raw.

## Risks / Trade-offs

- **[Low] Less detail in logs.** → Status and type identify the path; debug mode exists.
- **[Low] A server message could still contain user data,** for example a validation message that
  quotes the e-mail. It is shown to the same user, as in official clients, and never logged.

## Open Questions

_None._
