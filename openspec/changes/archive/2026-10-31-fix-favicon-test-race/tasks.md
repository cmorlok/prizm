# Tasks

## 1. Fix

- [x] 1.1 `testIconsOff_sendsNothing_andEmptiesTheCache` waits for `loader.generation == 1` (2 s deadline) after turning icons off (design D1). Done: de11548a.
- [x] 1.2 Unit tests green in three runs in a row, the test passing in each. Done: 20261030T195711Z, 20261030T195729Z, 20261030T195743Z. A second, separate flake in the same class (the stub's redirect follow-up reaching the next test) is fixed by `fix-favicon-stub-redirect-race`, stacked on this change.

## 2. Release

- [x] 2.1 CHANGELOG: not user-visible; no entry (test-only). Done: no entry.
- [x] 2.2 `openspec validate fix-favicon-test-race --type change --strict`. Done before the archive.
