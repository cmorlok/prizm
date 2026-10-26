# Tasks

Write a failing test first for each task (§IV).

## 1. Messages (0.25 d)

- [ ] 1.1 Failing tests for `APIError` descriptions with fixtures: Vaultwarden full and compact error, Bitwarden PascalCase validation error, Bitwarden identity error, 429, HTML body, empty body, a 1000-character message.
- [ ] 1.2 Implement design D1.

## 2. Logs (0.5 d)

- [ ] 2.1 Failing tests for `ErrorLog.describe`: `APIError`, `URLError`, a Swift enum with an associated string, `DecodingError`.
- [ ] 2.2 Implement design D2 and use it in every public error log; replace `EmptyTrashUseCaseImpl.describe`.
- [ ] 2.3 Check: no `\(error…, privacy: .public)` left outside `ErrorLog` (grep in the PR description).

## 3. Release (0.25 d)

- [ ] 3.1 Security review: no body, message or user data in public logs; shown messages match the official order.
- [ ] 3.2 CHANGELOG "Fixed": server errors show the server's message instead of the raw response, and logs no longer contain response bodies.
- [ ] 3.3 `openspec validate server-error-texts --type change --strict`.
