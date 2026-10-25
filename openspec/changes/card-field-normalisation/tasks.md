# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies.

## 1. Brand (0.75 d)

- [ ] 1.1 Failing table-driven tests for `CardBrand.canonical(for:)` (design D1): canonical values, display names, case and whitespace variants, unknown → custom, empty → not set.
- [ ] 1.2 Failing table-driven tests for `CardBrand.detect(number:)` using the official pattern list and order (`card.view.ts:88-148`), including Mastercard 2-series, Diners Carte Blanche, Visa Electron, and a number with no match.
- [ ] 1.3 Implement both in Domain (Foundation only).

## 2. Expiry (0.5 d)

- [ ] 2.1 Failing tests for `ExpiryMonth.canonical(for:)`: "1", "01", " 3 ", "12", "13", "Mar", "".
- [ ] 2.2 Failing tests for `ExpiryYear.normalised(_:currentYear:)` mirroring `normalizeExpiryYearFormat` (D3).
- [ ] 2.3 Implement; apply brand, month and year normalisation when the card draft is saved.
- [ ] 2.4 Failing view test, then implement D5 in `CardDetailView` (display and VoiceOver text).

## 3. Edit form (0.5 d)

- [ ] 3.1 Failing view-model test: the brand and month pickers expose the official options plus a custom entry only when needed; changing the number updates the brand (D2).
- [ ] 3.2 Replace the three rows in `CardEditForm.swift:16-29` with the D4 controls. DesignSystem tokens only.
- [ ] 3.3 VoiceOver: picker labels "Brand", "Expiry month", "Expiry year"; values read as display names (§VIII). Extend the accessibility UI test for the card form.

## 4. Blank URI rows (0.25 d)

- [ ] 4.1 Failing test: a new login saved with its initial empty row sends no URI; a login with one filled and one whitespace row sends one URI.
- [ ] 4.2 Implement D6 in the save path (`DraftVaultItem` → `toRawCipher`). If `fix-read-mapping-lossless-fields` has landed, add a test that a server `uri: null` row is still sent back.

## 5. Release (0.25 d)

- [ ] 5.1 Interop check: create a card in Prizm with an Amex number and expiry "03" / "27"; the web vault shows the Amex brand and 03 / 2027. Create a login without a website; the web vault shows no website row.
- [ ] 5.2 CHANGELOG "Changed": card brand and expiry are now chosen from lists and saved in the same format as Bitwarden apps; the brand is detected from the card number. "Fixed": new logins no longer get an empty website entry.
- [ ] 5.3 `openspec validate card-field-normalisation --type change --strict`.
