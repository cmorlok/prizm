## ADDED Requirements

### Requirement: Statistical tests repeat only the per-sample work
A unit test that draws many samples SHALL do set-up and validation (loading or filtering resources,
building lookup tables) once, before its sampling loop, so the whole unit-test run stays short and
the test host's main thread is never blocked for long.

#### Scenario: Passphrase uniformity test
- **WHEN** `testPassphraseWordPicks_areUniform` makes its 50,000 passphrases
- **THEN** the word list is validated once and each passphrase only picks words, and the test takes
  seconds, not minutes, in a Debug build
