# Design

## Context

`IconStub` is a `URLProtocol` with static state (answer, recorded requests, delay) that every test
resets in `setUp` and `tearDown`. For `.redirect(location)` it calls
`client.urlProtocol(_:wasRedirectedTo:redirectResponse:)` and then, in the same turn,
`didReceive(302)` and `urlProtocolDidFinishLoading`. When the session's delegate follows the
redirect, the URL loading system stops this protocol and starts a new one for the target, at a time
of its choosing; when the delegate refuses, the 302 is the result.

## Decisions

### D1. Finish with the 302 only when the redirect was refused

After `wasRedirectedTo`, the stub waits 50 ms on a background queue and finishes with the 302 only
if the system has not called `stopLoading` meanwhile (it does so when it follows). The cancelled
flag is lock-protected. A refused redirect still ends as a 302, as before.

### D2. Requests from a finished test are not recorded

`IconStub.reset()` starts a new epoch. A redirect target is sent with the epoch of the request that
redirected (a `URLProtocol` property). `startLoading` answers a request whose epoch is not the
current one with 404 and does not record it. Requests the loader makes itself carry no epoch and are
always recorded.

**Rejected alternative:** let every test wait until all requests are done. Tests cannot see the
follow-up request the loading system starts later.

## Risks / Trade-offs

- **[Low] 50 ms per refused redirect** in a test. A few tests use it; the delay is negligible.

## Open Questions

None.

## Review

- Found 2026-10-31 while diagnosing FaviconLoaderTests flakes that `fix-favicon-test-race` did not
  explain (`testRepeatedRequest_comesFromTheMemoryCache`, `testRedirectToAnotherHost_isFollowedWhenAllowed`):
  a redirect follow-up of one test reached `IconStub` after the next test's `reset()`.
- Red 20261031T182105Z (compile); green three runs in a row (20261031T182225Z, 182241Z, 182254Z),
  18 FaviconLoaderTests passing each time; per-commit run 20261031T183649Z (1365).
- Test-only change: no app code, no CHANGELOG entry, no UI impact.
