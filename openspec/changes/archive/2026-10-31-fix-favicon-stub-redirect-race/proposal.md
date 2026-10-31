# Proposal

## Why

`FaviconLoaderTests` (from `fix-website-icons-privacy`) fails now and then in tests that have
nothing in common: `testRepeatedRequest_comesFromTheMemoryCache` (one request too many, twice in a
row on 2026-10-31) and `testRedirectToAnotherHost_isFollowedWhenAllowed` (no image). Both come from
the test's URL stub, `IconStub`. For a redirect it reports the redirect and then, straight away,
also finishes the original request with the 302:

- When the session follows the redirect, the follow-up request can start after its test has ended.
  It is then recorded in the next test's request list (`testRepeatedRequest_…` runs right after
  `testRedirectWithinTheServer_isFollowed`), which then counts one request too many.
- In the test that follows the redirect, the 302 sometimes finishes first, and the loader gets no
  image.

`fix-favicon-test-race` fixed a different race in the same class. Flaky tests hide real failures and
spoil the red/green evidence of every change.

## What Changes

- `IconStub` finishes a redirected request with the 302 only when the session did not follow the
  redirect, and a follow-up request that arrives after its test has ended is answered without being
  recorded.
- `unit-test-isolation` gains a rule: a URL stub never lets a request of one test reach another.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `unit-test-isolation`: URL stubs keep the requests of one test out of the next.

## Non-Goals

- Changing `FaviconLoader` or its redirect policy (fix-website-icons-privacy, D5); they are right.

## Impact

- **Tests only:** `PrizmTests/Data/FaviconLoaderTests.swift` (`IconStub`), which
  `RootViewModelLockTests` also uses.

## Dependencies

- Stacked on `fix-favicon-test-race` (fix/036): another test and another cause, but the same file,
  and its race would keep `FaviconLoaderTests` red in this branch's evidence runs. Both add a
  requirement to `unit-test-isolation`.

## Estimate

0.2 d.
