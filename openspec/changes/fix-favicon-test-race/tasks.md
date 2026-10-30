# Tasks

## 1. Fix

- [ ] 1.1 `testIconsOff_sendsNothing_andEmptiesTheCache` waits for `loader.generation == 1` (2 s deadline) after turning icons off (design D1).
- [ ] 1.2 Unit tests green in three runs in a row, the test passing in each.

## 2. Release

- [ ] 2.1 CHANGELOG: not user-visible; no entry (test-only).
- [ ] 2.2 `openspec validate fix-favicon-test-race --type change --strict`.
