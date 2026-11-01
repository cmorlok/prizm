# Tasks

## 1. Fix

- [x] 1.1 `PasswordGenerator.generatePassphrase(config:provider:from:)`; the existing method validates and calls it (design D1). Done.
- [x] 1.2 `testPassphraseWordPicks_areUniform` validates the list once and uses the overload; it takes seconds, not minutes. Done: 98.684 s before (20261101T081144Z), 1.710 s after (20261101T081625Z).
- [x] 1.3 Unit tests green; no other test above a few seconds. Done: 20261101T081625Z, 1582 passed, 0 failed; next slowest `RootViewModelLockDuringSyncTests.testLockDuringUnlockSync_staysLockedWhenTheSyncEnds` 2.3 s (a deadline wait; 0.8 s or less in earlier runs).

## 2. Release

- [x] 2.1 CHANGELOG: not user-visible; no entry (test-only effect). Done: no entry.
- [x] 2.2 `openspec validate fix-passphrase-test-speed --type change --strict`. Done before the archive.
