# Design

## Context

`PasswordGenerator` (after `fix-password-generator`) builds a password from up to five sets
(upper 26, lower 26, digits 10, special 8, extended special 21; avoid ambiguous removes `I O l 0 1 |`)
with a minimum per enabled set, filled up to `effectiveLength` from the union and shuffled, every
choice uniform. A passphrase is `wordCount` uniform picks from 7,772 words, optionally with one
digit appended to one uniformly chosen word. Capitalizing and the separator are fixed by the
settings and add nothing.

## Decisions

### D1. Entropy from the settings, not from the text

- **Password:** log2 of the number of passwords the settings allow: strings of the effective
  length over the enabled sets (after the ambiguous filter) that contain at least each set's
  minimum (1, or the user's minimum for numbers and special). Counted as the sum over the set
  counts of the multinomial times `size^count`, in log space by a small dynamic program
  (`GeneratorStrength.passwordSpaceBits`). Defaults: 97.7 bits.
  Changed after the review (2026-10-31): the first version used `effectiveLength × log2(pool)`,
  which overstates little for the defaults (98.1) but much with high minimums (length 12 with at
  least 9 numbers: 73.6 instead of 52.7, OK instead of Weak).
  The generator is not exactly uniform over these passwords (required characters first, then the
  shuffle), so the real entropy is slightly lower; the tooltip says so.
- **Passphrase:** `wordCount × log2(listSize)`, plus `log2(10) + log2(wordCount)` when a number is
  included. `listSize` is the filtered word list (7,772). With an empty separator this is an upper
  bound: the EFF list is not prefix-free, so different word sequences can give the same text.
- Domain type `GeneratorStrength(bits: Double, category: Category)` with
  `static func of(_ config: PasswordGeneratorConfig, wordListSize: Int) -> GeneratorStrength`; the
  pool sizes come from `PasswordGenerator`'s sets, so the two can never disagree.

### D2. Categories and colors (Christian, 2026-10-30)

| Category | Bits | Color |
|---|---|---|
| Weak | < 64 | red |
| OK | 64 to < 80 | orange at 64, yellow towards 80 (linear by bits) |
| Strong | 80 to < 128 | green |
| Very strong | ≥ 128 | green |

Thresholds live in `GeneratorStrength.Threshold` (enum namespace). 64 bits is within reach of an
offline attack on a fast hash; 128 bits is the AES-128 security level.

The bar's filled share is `min(bits / 128, 1)`, so "Very strong" is a full bar. Category is never
conveyed by color alone (§VIII): the label always names it.

### D3. Presentation

- A `StrengthMeterView` under the preview: the bar (height `Spacing.strengthBarHeight`, 6 pt) and
  the text "Strong · 97 bits" in `Typography.utility`.
- One accessibility element: label "Strength", value "Strong, 97 bits"; identifier
  `generator.strength`.
- Hidden while `errorMessage` is set (no value, no strength).
- The view model exposes `strength: GeneratorStrength?`, recomputed in `generate()`; the word-list
  size comes from `PasswordGenerator.wordList()` (already cached).

## Risks / Trade-offs

- **[Low] The count is an upper bound on the real entropy** (D1): the generator is not exactly
  uniform over the passwords it can produce. Accepted; the tooltip says "Entropy of the generator's
  settings; the exact value is slightly lower when minimums are set."
- **[Low] Users may read "Strong" as a guarantee.** The tooltip states what is measured.

## Open Questions

None. Thresholds, colors and the "category · bits" label were decided by Christian (2026-10-30).
