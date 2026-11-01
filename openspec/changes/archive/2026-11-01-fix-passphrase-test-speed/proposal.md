# Proposal

## Why

`PasswordGeneratorParityTests.testPassphraseWordPicks_areUniform` (from `fix-password-generator`)
takes about 100 seconds of a unit-test run that otherwise finishes in seconds (98.7 s in
20261101T081144Z; the next slowest test takes 0.8 s). It makes 50,000 passphrases, and every
`generatePassphrase` call re-validates the 7,776-word list, filtering it for hyphenated words:
about 389 million string checks in a Debug build. The unit tests run inside the Prizm app on its
main thread, so the app window freezes for the whole time (spinning cursor, reported by
Christian 2026-11-01), and a host that does not answer for so long may be what made the test fail
once in 0.000 s without a message (20261031T180719Z).

## What Changes

- `PasswordGenerator` gets an overload `generatePassphrase(config:provider:from:)` that takes a
  word list already returned by `wordList()`. The existing method validates the list and calls it,
  so app behaviour is unchanged (a missing or wrong word list still gives `wordListUnavailable`).
- The uniformity test validates the list once and uses the overload.
- `unit-test-isolation` gains a rule: a statistical test does its per-sample work only, and repeats
  no set-up per sample.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `unit-test-isolation`: ADDED requirement on per-sample work in statistical tests.

## Impact

- `Prizm/Domain/Utilities/PasswordGenerator.swift` (one overload), one test.
- No user-visible change, no CHANGELOG entry.
