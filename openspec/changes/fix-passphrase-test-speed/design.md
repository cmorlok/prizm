# Design

## Context

`generatePassphrase(config:provider:)` calls `wordList()`, which reads the bundled list (cached in
`BundleWordListSource`) and filters out the 4 hyphenated words, checking the count each time. That
costs little per click in the app, but the uniformity test calls it 50,000 times.

## Decisions

### D1. An overload that takes the validated list

The public method stays as it is for the app and validates on every call, so a broken resource
cannot slip through. The overload `generatePassphrase(config:provider:from:)` does the picking; its
doc comment says the list must come from `wordList()`.

Alternatives: caching the filtered list in `PasswordGenerator` (a struct with an injected source; a
cache would need a reference type or a static keyed by source, more code for a test-only gain), or
fewer samples in the test (weaker statistics at the chosen p = 0.001 bound).

## Risks / Trade-offs

- **[Low] A caller passes a list that did not come from `wordList()`.** → Only the test does; the
  doc comment states the contract.
