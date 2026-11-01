# Tasks

## 1. Fix

- [ ] 1.1 Red: a Release build of `origin/develop` fails with "cannot find 'UITestFixtures' in scope" (`scripts/container/host-build.sh release`).
- [ ] 1.2 Move the UI-test check of `transitionToVault` into `#if DEBUG` (design D1); the Release build succeeds.
- [ ] 1.3 Unit tests green.

## 2. Release

- [ ] 2.1 CHANGELOG entry under Fixed.
- [ ] 2.2 `openspec validate fix-release-build --type change --strict`.
