# Tasks

## 1. Fix

- [x] 1.1 Red: a Release build of `origin/develop` fails with "cannot find 'UITestFixtures' in scope" (`scripts/container/host-build.sh release`). Done: 20261101T102257Z, `PrizmApp.swift:506:25`, the only error.
- [x] 1.2 Move the UI-test check of `transitionToVault` into `#if DEBUG` (design D1); the Release build succeeds. Done: ec6b3436; Release build 20261101T102313Z succeeded.
- [x] 1.3 Unit tests green. Done: 20261101T102341Z, 1583 passed, 0 failed.

## 2. Release

- [x] 2.1 CHANGELOG entry under Fixed. Done.
- [x] 2.2 `openspec validate fix-release-build --type change --strict`. Done before the archive.
