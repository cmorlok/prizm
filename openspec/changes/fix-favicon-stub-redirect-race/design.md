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
