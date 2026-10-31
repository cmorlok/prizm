# Proposal

## Why

**Criticality:** P2 (Medium)
**Findings:** CF-12, CF-13, CF-23 (`06-client-features.md`); wrong default claim in
`openspec/changes/archive/2026-03-23-password-generator/design.md:95`

Three problems in `Domain/Utilities/PasswordGenerator.swift`:

1. **Biased sampling (CF-12).** Characters, shuffle positions and words are picked with
   `byte % n` and `UInt16 % 7776` (`:63-64, 73, 81, 101-102, 113-114`). For words, 65536 is not a
   multiple of 7776, so the first 3,328 words are 12.5 % more likely than the rest. A 91-character
   pool gives 6.49 instead of 6.51 bits per character. The loss is small (about 0.2 %), but it is a
   defect in security code with a known fix.
2. **Character sets and defaults differ from Bitwarden (CF-13).** Prizm's symbol set is 29
   characters (`!@#$%^&*()_+-=[]{}|;':",.<>?/`), which includes quotes, `<>` and `|` that some sites
   and shells reject. Bitwarden uses `!@#$%^&*`. Prizm's "avoid ambiguous" also removes `|`. Defaults
   differ (length 16 with symbols on; Bitwarden: 14 without). Prizm has no "minimum numbers" or
   "minimum special" settings, allows 3–10 passphrase words (Bitwarden 3–20) and any separator length
   (Bitwarden: at most one character). Bitwarden also drops the four hyphenated EFF words
   (`drop-down`, `felt-tip`, `t-shirt`, `yo-yo`), which make "-"-separated passphrases ambiguous.
3. **Silent empty passphrase (CF-23).** If the bundled word list fails to load, `generatePassphrase`
   returns `""` (`:17-23, 95`). Nothing is logged or shown.

User-visible impact: generated passwords that some sites reject; settings that do not match the
other Bitwarden apps; in the failure case an empty "password" offered for use.

**Origin of the current behaviour:**
- Sampling: wrong premise, commit c95e172. `PasswordGenerator.swift:56-58`: "Note: `byte % count`
  introduces slight modulo bias … Acceptable for password generation; matches Bitwarden's own
  approach." Bitwarden samples uniformly (design.md, Context).
- Symbol set, 3–10 words: deliberate, `openspec/changes/archive/2026-03-23-password-generator/design.md:105`
  and `proposal.md:16`. The design left the symbol set as an open question.
- Default words: correct (6), but justified with a wrong claim. `design.md:95`: "The default of
  6 words was chosen over Bitwarden's 3-word default". The SDK struct default is 3, but the clients
  default to 6.
- Empty string: accidental.

## What Changes

Decided with Christian (2026-10-30): Prizm does not copy Bitwarden's defaults or limits just because
Bitwarden has them; it fixes the defects and adds what has a reason of its own.

- **Uniform sampling** for characters, shuffle, words, the digit and its position, by rejection
  sampling on the injected randomness provider.
- **Two symbol options instead of one.** "Special" is Bitwarden's `!@#$%^&*`, the set sites accept
  most widely. A new "Extended special" option holds the other 21 characters of today's set
  (`()_+-=[]{}|;':",.<>?/`). Each toggle label lists its characters.
- **Avoid ambiguous** removes `I O l 0 1`, and `|` from the extended set.
- **Defaults stay Prizm's:** length 16; upper, lower, numbers and special on; extended special off;
  avoid ambiguous off; minimum numbers 1; minimum special 0 (at least 1 whenever a set is on).
- **Minimum numbers and minimum special** controls, 0–9 (`org-policies` builds on them).
- **Passphrase:** 3–20 words, default 6; the separator stays free text of any length; hyphenated
  words excluded (they make "-"-separated passphrases ambiguous).
- **Word list failure** throws a typed error, logs at `.fault`, and the generator shows an error
  instead of an empty value.
- **Docs:** correct the 3-word claim; update the main `password-generator` spec.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `password-generator`: the password and passphrase requirements change (symbol options, minimums,
  word range, hyphen filter); uniform sampling and the visible word-list failure are added.

## Non-Goals

- Generator history (Bitwarden keeps a local list of generated values).
- Username generators, custom required or allowed characters, maximum consecutive characters (newer
  SDK options, not in the desktop UI).
- Organization generator policies: `org-policies`.

## Dependencies

- None hard.
- **Soft:** `org-policies` builds its generator policy on the min-count support added here.
- **Soft:** `clipboard-hardening` changes the generator's Copy; no overlap in this file.

## Impact

- **Domain:** `PasswordGenerator` (sampling, sets, word filter, error), `PasswordGeneratorConfig`
  (`includeExtendedSymbols`, `minNumbers`, `minSpecial`, bounds), new `PasswordGeneratorError.wordListUnavailable`.
- **Presentation:** extended special toggle, two steppers, word stepper 3–20, error display.
- **Existing users:** stored settings are kept. Their symbols toggle now means the 8 special
  characters; the extended set starts off (design.md D3).
- **No new dependencies.**
- **Security review required:** yes (random sampling for secrets).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Uniform index sampler and shuffle, statistical tests | 1 d |
| 2 | Character sets, defaults, min counts in the generator | 1 d |
| 3 | UI: min-count steppers, word range, separator, VoiceOver | 0.5–1 d |
| 4 | Passphrase: hyphen filter, uniform digit, word-list error | 0.5 d |
| 5 | Security review, docs, CHANGELOG, spec repair | 0.5–1 d |
| **Total** | | **3.5–4.5 d** |
