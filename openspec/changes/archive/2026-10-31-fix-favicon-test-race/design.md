# Design

## Context

`FaviconLoader` observes `UserDefaults.didChangeNotification` and, in a `Task`, resets itself when
"Show website icons" changes from on to off (`settingsChanged`). `reset()` increments `generation`.
The test sets the key to false, asks for an icon (nil, because `favicon(for:)` reads the setting
directly), sets the key to true and asks again, expecting a second request. Whether the reset ran
before the key went back to true depends on scheduling.

## Decisions

### D1. Wait for the reset, with a deadline

After setting the key to false, the test polls `loader.generation` until it is 1 (5 ms steps, 2 s
deadline) and fails with a message if it never changes. Same pattern as
`testTurningIconsOff_resetsTheLoader`.

**Rejected alternative:** call `reset()` from the setter synchronously. It would change app code to
suit a test, and the notification path is what the app relies on.

## Risks / Trade-offs

None.

## Open Questions

None.

## Review

- Code review (2026-10-31, in the batch-3 review round): no finding.
- `/opsx:verify` (2026-10-31): clean (one optional helper suggestion declined: two uses only).
- Unit tests green three times in a row (20261030T195711Z, 195729Z, 195743Z) and at the branch tip
  (20261031T182225Z-series runs on the stacked `fix-favicon-stub-redirect-race`). A second flake in
  the same class had another cause and is fixed by `fix-favicon-stub-redirect-race`.
