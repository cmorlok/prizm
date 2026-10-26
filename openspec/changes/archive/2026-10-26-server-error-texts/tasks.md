# Tasks

Write a failing test first for each task (§IV).

## 1. Messages (0.25 d)

- [x] 1.1 Failing tests for `APIError` descriptions with fixtures: Vaultwarden full and compact error, Bitwarden PascalCase validation error, Bitwarden identity error, 429, HTML body, empty body, a 1000-character message.
- [x] 1.2 Implement design D1.

## 2. Logs (0.5 d)

- [x] 2.1 Failing tests for `ErrorLog.describe`: `APIError`, `URLError`, a Swift enum with an associated string, `DecodingError`.
- [x] 2.2 Implement design D2 and use it in every public error log; replace `EmptyTrashUseCaseImpl.describe`.
- [x] 2.3 Check: no `\(error…, privacy: .public)` left outside `ErrorLog` (grep in the PR description).

## 3. Release (0.25 d)

- [x] 3.1 Security review: no body, message or user data in public logs; shown messages match the official order.
- [x] 3.2 CHANGELOG "Fixed": server errors show the server's message instead of the raw response, and logs no longer contain response bodies.
- [x] 3.3 `openspec validate server-error-texts --type change --strict`.

## Results (2026-10-26)

- Fixtures from Vaultwarden 1.37.4 (`src/error.rs`) and the Bitwarden server; order as in the
  official `ErrorResponse`. `ServerErrorTextTests`: 11 tests.
- 63 public error logs now use `ErrorLog.describe`; `EmptyTrashUseCaseImpl` uses it instead of its own
  helper. Left as they are: 5 logs of fixed `AuthError` texts and 3 Security framework `CFError`
  descriptions (`PrizmCryptoService` ×2, `BiometricKeychainServiceImpl`; generic text, no user data).
- Review (2026-10-26, task 3.1): found the batch upload log (error message and attachment file
  name public; the first grep matched only some variable names), now `ErrorLog.describe` and the
  file name private; the `APIError` extensions made `nonisolated` (actors log through them) with an
  off-main-actor test; `KeychainError` keeps its OSStatus; the validation key order deviation is in
  design D1. Out of scope, noted for later: the org name (`SyncRepositoryImpl`, info) and an item
  domain (`FaviconLoader`, debug) are logged publicly.
- `SECURITY.md`: the open item from `harden-key-lifecycle-and-logging` is replaced by an "Error
  logging" section.
- Unit tests: 714 passed on the Mac.

