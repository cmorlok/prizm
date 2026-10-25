# Proposal

## Why

**Criticality:** P3 (Low: parity)
**Findings:** W-16, W-17 (`04-write-paths.md`)

**Card brand and expiry are free text.** The card edit form uses plain text rows for brand, expiry
month and expiry year (`Prizm/Presentation/Vault/Edit/CardEditForm.swift:16-29`). Users type values
like "visa", "03" or "25". Official clients store brand from a fixed list ("Visa", "Amex", …),
month as "1"–"12" without a leading zero, and year as four digits. Other clients then show no brand
icon or label for Prizm's cards, and may misread the expiry (for example in autofill or expiry
checks). There is no brand detection from the card number.

**A new login has an empty website.** A new login starts with one URI `""`
(`Prizm/Domain/Entities/DraftVaultItem.swift:246`). If the user leaves it blank, Prizm encrypts and
sends an empty string, and other clients show an empty "website" row.

### Origin of the current behaviour

- **Card fields: unclear, no recorded decision.** The only trace is the form's comment "All card
  fields are editable text fields" (`CardEditForm.swift:7`).
- **Blank URI: accidental.** The blank draft adds one URI row for convenience; nothing removes it
  when left empty.

## What Changes

- **Brand picker.** Brand is chosen from the official list: Visa, Mastercard, American Express
  (stored as "Amex"), Discover, Diners Club, JCB, Maestro, UnionPay, RuPay, Other, plus "Not set".
- **Brand detection.** When the card number changes and matches a known pattern, the brand is set,
  as in the web vault.
- **Expiry pickers.** Month is a picker "01 - January" … "12 - December" that stores "1"–"12".
  Year is a text field that is normalised to four digits on save ("25" → "2025"), using the
  official rule.
- **Existing values are kept.** Brand and month values that match an official value in another
  spelling ("visa", "03") are mapped to it. Values that match nothing are shown as an extra
  "<value> (custom)" option and saved unchanged unless the user picks another.
- **No blank URI on a new login.** URI rows the user left blank are not sent.
- Detail view shows the expiry as "MM / YYYY" when both are numeric.

## Capabilities

### New Capabilities
- `item-field-normalisation`: card brand and expiry, and blank login URIs, are written in the
  format official Bitwarden clients write.

### Modified Capabilities
_None._ No living spec describes card field formats or the initial URI row.

## Non-Goals

- Identity title picker (Mr, Mrs, Ms, Mx, Dr). Also free text today; possible follow-up.
- Card number formatting or Luhn validation. Official clients don't validate either.
- Rewriting stored cards that Prizm or users created earlier. Values are normalised only when an
  item is saved.
- Value-less URIs that come from the server (`uri: null`). They are kept by
  `fix-read-mapping-lossless-fields`.

## Dependencies

- None hard.
- Soft: `fix-read-mapping-lossless-fields` (Domain URI value becomes optional; its design D2 leaves
  blank *new* URIs to this change).

## Impact

- **Domain:** `CardBrand` and `ExpiryMonth` helpers (Foundation only): canonical values, tolerant
  parsing, brand detection by number pattern, year normalisation. `DraftVaultItem` save-time
  filter for blank URIs.
- **Data:** none (formats are decided before `toRawCipher`).
- **Presentation:** `CardEditForm` pickers, `CardDetailView` expiry format, VoiceOver labels.
- **No new dependencies.**
- **Security review: no.** No keys, crypto or auth; card values stay encrypted as today.

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Brand list, tolerant mapping, detection by number | 0.75 d |
| 2 | Month picker, year normalisation, detail format | 0.5 d |
| 3 | Edit-form pickers with accessibility | 0.5 d |
| 4 | Blank URI rows not sent | 0.25 d |
| 5 | Interop check, CHANGELOG | 0.25 d |
| **Total** | | **2.25 d** |
