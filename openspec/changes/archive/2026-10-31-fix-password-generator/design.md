# Design

## Context

Sources: `sdk-internal` and `clients` at HEAD 2026-10-23. The TS clients generate through the SDK
(`libs/tools/generator/core/src/engine/sdk-password-randomizer.ts`).

**SDK password generator** (`crates/bitwarden-generators/src/password.rs`):
- Sets: `a-z`, `A-Z`, `0-9`, special `! @ # $ % ^ & *` (`:127-130`). Avoid-ambiguous removes `I O`,
  `l`, `0 1` (`:127-129, 254-269`).
- Minimum per enabled set: `max(min ?? 1, 1)`; 0 for disabled sets (`:236-245`). Too many minimums for
  the length is an error (`:247-251`).
- Each character: `rng.random_range(0..len)` over the set (`:174-178`), i.e. uniform. Required
  characters first, then the rest from the union, then `shuffle` (`:325-337`).
- Length bounds 5–128 for the UI (`:84-95`); the SDK rejects < 4 (`:228-230`). Min counts 0–9 (`:93-95`).

**TS defaults and bounds** (`libs/tools/generator/core/src/data/`):
- `default-password-generation-options.ts`: length 14, ambiguous `true` (= allowed, so "avoid
  ambiguous" off; mapped as `avoidAmbiguous: !settings.ambiguous`, `engine/sdk-password-randomizer.ts:80`),
  uppercase, lowercase, number on with min 1, special off with min 0.
- `default-password-boundaries.ts`: length 5–128, min digits 0–9, min special 0–9.
- `default-passphrase-generation-options.ts`: 6 words, separator "-", capitalize off, include number
  off.
- `default-passphrase-boundaries.ts`: 3–20 words.
- Separator at most one character (`policies/passphrase-policy-constraints.ts:21`).

**SDK passphrase** (`crates/bitwarden-generators/src/passphrase.rs`):
- Words 3–20 (`:48-50, 68-73`). Struct default 3 words and a space separator (`:36-43`); the clients
  override this with 6 and "-".
- Words chosen with `choose` from the EFF long list without hyphenated words (`:102-119`).
- Include number: random word, digit `random_range(0..=9)` (`:121-124`).
- The word list is compiled into the SDK (`bitwarden-crypto/src/wordlist.rs`, 7,776 words, 4 with
  "-").

**Prizm today** (`Domain/Utilities/PasswordGenerator.swift`, `PasswordGeneratorConfig.swift`):
- Sets at `:9-13`; symbol set 29 characters; ambiguous adds `|`.
- `byte % set.count` (`:63-64`), `byte % pool.count` (`:73`), shuffle `byte % (i + 1)` (`:81`),
  words `UInt16 % 7776` (`:101-102`), digit and word index `% 10`, `% words.count` (`:113-114`).
- Word list from `Bundle.main` (`Resources/eff-large-wordlist.txt`, 7,776 lines incl. the 4
  hyphenated words); failure → `[]` → `""` (`:17-23, 95`).
- Config defaults: length 16, all sets on, avoid ambiguous off, 6 words, "-" (`PasswordGeneratorConfig.swift:14-30`);
  persisted as `pwgen.*` in UserDefaults (`:34-60`).
- UI: words stepper 3–10, free-text separator (`Presentation/Vault/Edit/PasswordGeneratorView.swift:88-96`).
- Random source: `SecRandomCopyBytes` through `RandomnessProvider` (`Data/Crypto/CryptographicRandomnessProvider.swift`).

## Goals / Non-Goals

**Goals**
- Every character, position and word is chosen with exactly uniform probability from its set.
- With the special set on and the extended set off, a password generated with the same settings in
  Prizm and in a Bitwarden app comes from the same distribution.
- No silent failure.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Rejection sampling on the injected provider

`func uniformIndex(below n: Int, using provider: RandomnessProvider) throws -> Int`:
draw a `UInt32` (4 bytes), reject values `≥ limit` with `limit = (2^32 / n) * n` computed in
`UInt64` (a `UInt32` cannot hold 2^32, and `UInt32.max / n * n` differs whenever n divides 2^32,
for example n = 8), return `value % n`. The rejection probability is below `n / 2^32`, negligible
for `n ≤ 7776`. All picks, the Fisher–Yates shuffle, the digit and its word use it.

After 64 consecutive rejections the provider is treated as broken and
`PasswordGeneratorError.randomSourceFailed` is thrown (the chance of that from a working source is
below `(7776 / 2^32)^64`). A source that keeps returning one rejected value must not freeze the
popover (§V). The existing tests that use a constant-byte provider (all bytes 255) are updated: such
a provider now fails with that error, by design.

This is the standard method, the same property as `rand`'s `random_range` in the SDK. Tests:
- boundary: a scripted provider returns `limit - 1`, `limit`, `UInt32.max` (as 4 bytes each); the
  first is accepted as `(limit - 1) % n`, the other two are rejected;
- 64 rejections in a row throw `randomSourceFailed`;
- distribution: a seeded pseudo-random provider in the test mocks (SplitMix64; the existing
  `MockRandomnessProvider` cycles 0–255 and gives only 64 distinct 32-bit values) drives a
  chi-square test over 100,000 draws for n = 7, 8, 62, 70, 7772. The seed is fixed, so the result is
  deterministic; the threshold is the chi-square critical value at p = 0.001, checked once for the
  fixed seed.

**Rejected alternative:** wrap the provider in a `RandomNumberGenerator` and use the standard
library's `Int.random(in:using:)`. `RandomNumberGenerator.next()` cannot throw, so a provider failure
would have to crash or be swallowed. Constitution §V forbids the second, and a crash in a sheet is
worse than a shown error.

### D2. Sets and minimums

- Special `!@#$%^&*` (Bitwarden's set). Extended special `()_+-=[]{}|;':",.<>?/`: the other 21
  characters of Prizm's old symbol set, as their own set and toggle (Christian, 2026-10-30). The
  two sets are disjoint, so together they are exactly the old 29.
- Avoid ambiguous removes `I O l 0 1` from the letter and digit sets and `|` from the extended set.
- `minNumbers`, `minSpecial` in config (0–9). Effective minimum per enabled set is `max(min, 1)`,
  as in the SDK; disabled sets contribute 0. `minSpecial` applies to the special set; the extended
  set contributes at least 1 when on. If the minimums exceed the length, the length is raised to
  their sum (the TS constraints do the same, `policies/constraints.ts:21-22`).
- Order: required characters, then the rest from the union, then shuffle. Same as the SDK.
- When the minimums exceed the length, the view model raises `config.length` to their sum: the
  slider and the stored length follow, so what is shown is what is generated.
- A minimum of 0 behaves like 1 while its set is on; the stepper's help text says "at least 1 while
  … is on". The "Minimum special" stepper is enabled while the special set is on, "Minimum numbers"
  while numbers are on. Stored minimums are clamped to 0–9 on load, stored word counts to 3–20.
- The last-enabled-set lock counts five sets (upper, lower, numbers, special, extended special); the
  rule moves from the view into a tested view-model helper.
- Accessibility: the extended toggle's label is "Extended special characters", its value or hint
  lists the characters; identifiers `generator.toggle.extendedSymbols`, `generator.minNumbers`,
  `generator.minSpecial`. The visible labels are "Special (!@#$%^&*)" and
  "Extended special (()_+-=[]{}|;':",.<>?/)", wrapping in the 320 pt popover.

### D3. Defaults and existing users

Defaults stay Prizm's (Christian, 2026-10-30): length 16; upper, lower, numbers and special on;
extended special off; avoid ambiguous off; minimum numbers 1; minimum special 0. Stored `pwgen.*`
values are kept: a user who chose 20 characters keeps 20. The stored `pwgen.includeSymbols` keeps its
key and now means the special set; `pwgen.includeExtendedSymbols` starts off, so an existing user
who had symbols on gets the 8 special characters until they turn the extended set on. CHANGELOG
explains it.

One migration: when `pwgen.includeExtendedSymbols` is not stored yet and symbols were the only
enabled set, the extended set is turned on. Otherwise such a user would drop from 29 to 8 characters
(48 bits at length 16) without notice.

**Rejected alternatives:**
- Bitwarden's defaults (length 14, special off): no reason beyond parity, and weaker.
- Extended set on by default, or on for users who had symbols on: keeps the old output, but brings
  back the characters sites and shells reject most often (quotes, `<>`, `|`, `;`).

### D4. Passphrase

- Word count 3–20, default 6. Stored values outside the range are clamped.
- Separator: free text of any length, as today (Christian, 2026-10-30; Bitwarden's one-character cut
  has no reason of its own).
- Hyphenated words are filtered out once when the list loads (7,772 words remain).

### D5. Word list failure is an error

The word list comes through an injected source: `PasswordGenerator(wordListSource:)`, a Domain
protocol whose app implementation reads the bundled `eff-large-wordlist.txt` (read once per launch; a failed read stays a failure until the next launch, harmless for a
bundled resource);
tests pass a failing or a small source. A missing or unreadable resource, or a list that does not
have exactly 7,776 words before filtering, throws `PasswordGeneratorError.wordListUnavailable`.

Domain does not log (Foundation only). The view model logs the error at `.fault` (a missing bundled
resource is a build defect), shows its message (`PasswordGeneratorError` conforms to
`LocalizedError`: "The word list for passphrases couldn't be loaded."), announces it to VoiceOver
(§VIII), and disables Use and Copy while the value is empty.

**Rejected alternative:** compile the list into Swift source as the SDK does. It adds a 60 KB source
file for a failure that a unit test on the app bundle already catches.

## Risks / Trade-offs

- **[Low] Smaller default symbol set.** 70 instead of 91 characters with the extended set off: about
  0.38 bits less per character, about 98 bits at the default length 16. Users who want more turn
  the extended set on or raise the length. Accepted for site compatibility.
- **[Low] Test flakiness of statistical tests.** → A fixed seed makes them deterministic (D1).

## Open Questions

None. Closed 2026-10-30 (Christian): keep length 16 with symbols on; split the symbols into
"Special" (Bitwarden's 8) and "Extended special" (the other 21); 3–20 words with a separator of any
length.

## Review

- Spec challenge (fresh agent, before code): 15 findings, all adopted.
- Code review (fresh agent, 2026-10-31): 0 high/medium, 6 low, all fixed (red 20261031T074936Z,
  green 20261031T075159Z). The frequency check of task 5.2 passes as a characterisation test: the
  positions share the set mix, they are not uniform over the union of the sets.
- Security review (fresh agent, 2026-10-31): clean (uniform sampling via `SecRandomCopyBytes` with
  rejection, no modulo bias, no values in logs).
- `/opsx:verify` (2026-10-31): 0 critical, 0 warnings, 5 suggestions, done (toggle titles tested,
  D5 wording "read once per launch", `password.rs:174-178` cited; green 20261031T180933Z).
- UI: `PasswordGeneratorJourneyTests` passed in the final batch run 20261031T210247Z. VoiceOver hand
  check of the new controls (stepper read once): Christian, 2026-10-31.
- Seen once, not reproduced: `PasswordGeneratorParityTests.testPassphraseWordPicks_areUniform`
  failed in 0.000 s without a message (20261031T180719Z); every run since passed. Follow-up.
