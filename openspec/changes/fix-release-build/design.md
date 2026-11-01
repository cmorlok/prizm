# Design

## Context

UI-test seams (`UITestFixtures`, the conflict use cases, the in-memory keychains) are compiled only
in DEBUG builds, so a Release binary never contains a way to skip login or seed a vault. Every use
sits inside `#if DEBUG`, except the icon check that `fix-website-icons-privacy` added to
`transitionToVault`.

## Decisions

### D1. Guard the check, keep one code path for the icon base

The account's icon base is computed in every build; only DEBUG builds can replace it with nil when
UI tests run. Release builds get exactly the Debug behaviour outside UI tests.

Alternatives: a Release stub of `UITestFixtures.isEnabled` that always returns false (puts a test
type into the Release binary, against the seam's purpose).

### D2. No CI change in this change

CI builds and tests Debug only, so it did not catch the break. Building Release in CI is a
workflow change and is left as a follow-up; the requirement's scenario names the check
(`scripts/container/host-build.sh release`).

## Risks / Trade-offs

- **[Low] Another seam use outside `#if DEBUG` slips in again.** → Only a Release build finds it,
  until CI builds Release (D2).
