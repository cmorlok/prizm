# Tasks

## 1. Fix

- [ ] 1.1 Failing test: a request carrying an earlier epoch reaches `IconStub` after `reset()`; it is answered and not recorded (design D2).
- [ ] 1.2 `IconStub`: epoch on reset and on redirect targets; stale requests answered 404 and not recorded (D2); the 302 finishes only when the redirect was not followed (D1).
- [ ] 1.3 Unit tests green in three runs in a row, `FaviconLoaderTests` passing in each.

## 2. Release

- [ ] 2.1 CHANGELOG: not user-visible; no entry (test-only).
- [ ] 2.2 `openspec validate fix-favicon-stub-redirect-race --type change --strict`.
