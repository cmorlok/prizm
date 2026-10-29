# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies.

## 1. Brand (0.75 d)

- [x] 1.1 Failing table-driven tests for `CardBrand.canonical(for:)` (design D1): canonical values, display names, case and whitespace variants, unknown → custom, empty → not set.
- [x] 1.2 Failing table-driven tests for `CardBrand.detect(number:)` using the official pattern list and order (`card.view.ts:88-148`), including Mastercard 2-series, Diners Carte Blanche, Visa Electron, and a number with no match.
- [x] 1.3 Implement both in Domain (Foundation only).

## 2. Expiry (0.5 d)

- [x] 2.1 Failing tests for `ExpiryMonth.canonical(for:)`: "1", "01", " 3 ", "12", "13", "Mar", "".
- [x] 2.2 Failing tests for `ExpiryYear.normalised(_:currentYear:)` mirroring `normalizeExpiryYearFormat` (D3).
- [x] 2.3 Implement; apply brand, month and year normalisation when the card draft is saved.
- [x] 2.4 Failing view test, then implement D5 in `CardDetailView` (display and VoiceOver text).

## 3. Edit form (0.5 d)

- [x] 3.1 Failing view-model test: the brand and month pickers expose the official options plus a custom entry only when needed; changing the number updates the brand (D2).
- [x] 3.2 Replace the three rows in `CardEditForm.swift:16-29` with the D4 controls. DesignSystem tokens only.
- [x] 3.3 VoiceOver: picker labels "Brand", "Expiry month", "Expiry year"; values read as display names (§VIII). Extend the accessibility UI test for the card form.
  XCUITest `AccessibilityLabelTests.testCardExpiryAndPickers_readAsNamedValues`.

## 4. Blank URI rows (0.25 d)

- [x] 4.1 Failing test: a new login saved with its initial empty row sends no URI; a login with one filled and one whitespace row sends one URI.
- [x] 4.2 Implement D6 in the save path (`DraftVaultItem` → `toRawCipher`). If `fix-read-mapping-lossless-fields` has landed, add a test that a server `uri: null` row is still sent back.

## 5. Release (0.25 d)

- [x] 5.1 Interop check: create a card in Prizm with an Amex number and expiry "03" / "27"; the web vault shows the Amex brand and 03 / 2027. Create a login without a website; the web vault shows no website row.
  Checked 2026-10-26 on Vaultwarden 1.37.3 (Prizm could not save items on 1.37.4 yet, `encryptedFor`): the web vault shows the Amex brand and 03 / 2027; the login without a website was saved with `uris: []` and shows no website row.
- [x] 5.2 CHANGELOG "Changed": card brand and expiry are now chosen from lists and saved in the same format as Bitwarden apps; the brand is detected from the card number. "Fixed": new logins no longer get an empty website entry.
- [x] 5.3 `openspec validate card-field-normalisation --type change --strict`.

## Results (2026-10-26)

- Source check: brand values and month options as in `card-details-section.component.ts` and iOS
  `CardComponent`; `getCardBrandByPatterns` and `normalizeExpiryYearFormat` ported literally.
- `ItemFieldNormalisationTests`: brand and month mapping, detection table (Mastercard 2-series,
  Carte Blanche, Visa Electron, spaces, no match), year table, expiry display, save-time
  normalisation, blank website rows, and the edit sheet (edited card normalised, folder-only change
  sent unchanged, new login without website).
- Added design D7 (an edit of only folder/favorite is sent unnormalised, so it stays `/partial`)
  and D8 (year without digits kept). Review (2026-10-26): D7 first skipped normalisation for any
  edit with unchanged content (a rename sent "visa" unchanged); now it uses the repository's
  per-user-only test. Mastercard pattern anchored with `\z` (NSRegularExpression `$` also matched
  before a trailing newline). Detection overriding a picked brand, display text being copied and
  `uri: null` rows are recorded under Risks.
- 3.3: pickers carry the labels "Brand" and "Expiry Month"; the year field keeps "Expiry Year" with
  placeholder "YYYY"; VoiceOver reads the expiry as "March 2027". UI test:
  `AccessibilityLabelTests.testCardExpiryAndPickers_readAsNamedValues`.
- 4.2: `fix-read-mapping-lossless-fields` has not landed; no `uri: null` test yet.
- **Verified on the Mac (2026-10-26):** all 703 unit tests pass on this branch; the full UI suite passes on the top of the series (`fix/017`).
- Open: 5.1 interop on the rig.

## Verification (2026-10-26, `/opsx:verify`)

- No code gaps. The picker's entries (Not set, the official options, a custom entry only for a
  stored value that matches none) moved from the view into `CardFieldChoice.choices`, tested by
  `testPickerChoices_offerACustomEntryOnlyForACustomValue` (task 3.1).
- The requirement's sentence "Value-less URIs loaded from the server SHALL be kept" depends on
  `fix-read-mapping-lossless-fields` (design Risks); until then Prizm drops them on read.
- Open by design: 5.1 (test server).
- Second round (2026-10-26): the requirement sentence on value-less server URIs now states that it
  depends on `fix-read-mapping-lossless-fields`.

