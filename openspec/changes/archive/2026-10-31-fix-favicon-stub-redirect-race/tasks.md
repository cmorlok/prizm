# Tasks

## 1. Fix

- [x] 1.1 Failing test: a request carrying an earlier epoch reaches `IconStub` after `reset()`; it is answered and not recorded (design D2). Done: `testStubRequestOfAnEarlierTest_isAnsweredButNotRecorded`; red 20261031T182105Z (compile only: `IconStub.epoch` did not exist).
- [x] 1.2 `IconStub`: epoch on reset and on redirect targets; stale requests answered 404 and not recorded (D2); the 302 finishes only when the redirect was not followed (D1). Done: d437ab8c (epoch tag via `URLProtocol.setProperty`, lock-protected `_cancelled`, 302 finish delayed 50 ms).
- [x] 1.3 Unit tests green in three runs in a row, `FaviconLoaderTests` passing in each. Done: 20261031T182225Z, 20261031T182241Z, 20261031T182254Z (18 FaviconLoaderTests passed each time).

## 2. Release

- [x] 2.1 CHANGELOG: not user-visible; no entry (test-only). Done: no entry.
- [x] 2.2 `openspec validate fix-favicon-stub-redirect-race --type change --strict`. Done before the archive.
