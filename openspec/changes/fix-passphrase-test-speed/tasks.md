# Tasks

## 1. Fix

- [ ] 1.1 `PasswordGenerator.generatePassphrase(config:provider:from:)`; the existing method validates and calls it (design D1).
- [ ] 1.2 `testPassphraseWordPicks_areUniform` validates the list once and uses the overload; it takes seconds, not minutes.
- [ ] 1.3 Unit tests green; no other test above a few seconds.

## 2. Release

- [ ] 2.1 CHANGELOG: not user-visible; no entry (test-only effect).
- [ ] 2.2 `openspec validate fix-passphrase-test-speed --type change --strict`.
