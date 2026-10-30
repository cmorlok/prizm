# Proposal

## Why

Requested by Christian (2026-10-30). The password generator shows a value but not how strong it is.
Users change length, sets and word count without seeing what the change does to the strength.
Prizm can compute the strength exactly from the settings, because it knows the sets and the random
choices it makes; it does not have to guess from the text as a strength checker for typed
passwords must.

## What Changes

- The generator popover shows the entropy of the value it generates, in bits, computed from the
  current settings, with a colored bar and a category:
  - **Weak** below 64 bits: red
  - **OK** 64 to 79 bits: orange to yellow, by bits
  - **Strong** 80 to 127 bits: green
  - **Very strong** from 128 bits: green
- The label shows category and bits ("Strong · 97 bits"); VoiceOver reads both.
- The meter updates on every settings change and is hidden while the generator shows an error.

## Capabilities

### New Capabilities
- `generator-strength-meter`: the generator shows the entropy of its settings with a category and
  a colored bar.

### Modified Capabilities
_None._

## Non-Goals

- Strength of passwords the user types in the edit sheet (that needs a guessing model such as
  zxcvbn, which the official clients use; a separate change if wanted).
- Policies that block weak values (`org-policies`).

## Dependencies

- **Hard:** `fix-password-generator` (stacked on `fix/034`): the meter uses its character sets,
  minimums, effective length and filtered word list.

## Impact

- **Domain:** `GeneratorStrength` (entropy and category from a `PasswordGeneratorConfig` and the
  word-list size), thresholds in an enum namespace.
- **Presentation:** `PasswordGeneratorViewModel.strength`; a `StrengthMeterView` in the popover;
  one new `Spacing` token for the bar height.
- **No new dependencies.**

## Estimate

| Step | Scope | Estimate |
|---|---|---|
| 1 | Entropy and category, unit tests | 0.25 d |
| 2 | Meter view, VoiceOver, view model wiring | 0.25 d |
| 3 | UI test, docs | 0.25 d |
| **Total** | | **0.75 d** |
