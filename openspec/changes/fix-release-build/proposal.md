# Proposal

## Why

The Release configuration does not compile on `develop` since `fix-website-icons-privacy`
(7b23917c): `RootViewModel.transitionToVault` reads `UITestFixtures.isEnabled`
(`Prizm/App/PrizmApp.swift:506`), but `UITestFixtures` exists only in DEBUG builds
(`Prizm/App/UITestFixtures.swift` is wrapped in `#if DEBUG`). `xcodebuild … -configuration Release`
fails with "cannot find 'UITestFixtures' in scope", so no release or archive can be built. Debug
builds, the unit tests and CI (which builds Debug only) do not notice. Found by the security review
of `lock-state-machine` on 2026-11-01.

## What Changes

- The UI-test check in `transitionToVault` moves into `#if DEBUG`; Release builds configure the
  icon loader with the account's server, as Debug builds outside UI tests do.
- `release-infrastructure` gains a requirement: the Release configuration compiles, and test seams
  are referenced only inside `#if DEBUG`.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `release-infrastructure`: ADDED requirement that the Release configuration compiles.

## Impact

- `Prizm/App/PrizmApp.swift` (one statement).
- No behaviour change in Debug builds; Release builds can be made again. CHANGELOG entry under
  Fixed (a release build is user-facing for anyone building from source).
