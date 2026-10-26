# Design

## Context

Sources: `$SRC` checkouts of 2026-10-23 (clients, ios).

**Web cipher form, card section** (`clients/libs/vault/src/cipher-form/components/card-details-section/card-details-section.component.ts`):
- Brands (`:69-81`): select with "-- Select --" (`null`), Visa, Mastercard, American Express →
  `"Amex"`, Discover, Diners Club, JCB, Maestro, UnionPay, RuPay, Other → `"Other"`.
- Months (`:84-98`): "01 - January" → `"1"` … "12 - December" → `"12"`, plus "-- Select --".
- Year: on every form change, `normalizeExpiryYearFormat(expYear)` (`:118`). The function keeps a
  4-digit year starting 1–9, strips non-digits and leading zeros, and turns 1–3 digit or >4 digit
  input into current century + last two digits (`clients/libs/common/src/autofill/utils/index.ts:21-52`).
- Brand detection: when the number changes, `CardView.getCardBrandByPatterns(number)` sets the brand
  if a pattern matches (`card-details-section.component.ts:130-138`). Patterns: Visa `^4`,
  Mastercard (2017 BIN ranges, full 16-digit match), Amex `^3[47]`, Discover, Diners `^36` and
  `^30[0-5]`, JCB `^35(2[89]|[3-8][0-9])`, Visa Electron (`clients/libs/common/src/vault/models/view/card.view.ts:88-148`).
  Maestro, UnionPay and RuPay are selectable but never detected.
- An existing value that is not in the list stays in the form value and is saved unchanged
  (`initFromExistingCipher`, `:153-162`).

**iOS** uses the same brand raw values ("Visa" … "Amex" … "Other") and month raw values 1–12
(`ios/BitwardenShared/UI/Vault/VaultItem/AddEditItem/AddEditCardItem/CardComponent.swift:14-47, 91-118`).

**New login URI.** The web form starts a new login with one URI row whose value is `null`
(`clients/libs/vault/src/cipher-form/components/autofill-options/autofill-options.component.ts:220-224`),
and maps rows to `LoginUriView` without filtering (`:132-141`). So the official request carries a
URI with `uri: null`, not an encrypted empty string.

**Prizm today.**
- `CardEditForm.swift:16-29`: brand, month, year as `OptionalEditFieldRow` (free text).
- `CardDetailView.swift:36-45`: expiry shown as `[expMonth, expYear]` joined.
- `DraftVaultItem.swift:246`: `uris: [LoginURI(uri: "", matchType: nil)]` for a new login.
- `CipherMapper.toRawLogin` encrypts every URI string, including `""`
  (`Prizm/Data/Mappers/CipherMapper.swift:416-420`).

## Goals / Non-Goals

**Goals**
- Cards saved by Prizm use the same brand, month and year values as official clients.
- No value a user or another client stored is lost or silently changed into something else.
- New logins don't get an empty website.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Canonical values and tolerant mapping (Domain)

`CardBrand.canonical(for: String?) -> CardBrandValue`:
- `nil` or empty → `.notSet`
- case-insensitive, trimmed match of a canonical value or its display name ("visa", "VISA",
  "american express", "amex", "diners", "mastercard") → `.known("Visa")` etc.
- anything else → `.custom(original)`

`ExpiryMonth.canonical(for:)`: trimmed integer 1–12, with or without a leading zero → `.known("3")`;
else `.custom(original)`; empty → `.notSet`.

**Rejected alternative:** keep unknown values out of the picker and clear them. That loses data a
user or another client stored on purpose.

### D2. Detection by number

Port `getCardBrandByPatterns` exactly (same order and regexes, `card.view.ts:88-148`) as
`CardBrand.detect(number:)`. When the number field changes and detection returns a brand, the
picker is set to it, as the web form does. No detection on load, so an existing manual choice is
not overwritten until the number is edited.

### D3. Year normalisation

Port `normalizeExpiryYearFormat` (`autofill/utils/index.ts:21-52`) as `ExpiryYear.normalised(_:)`,
with the current year passed in for testability. Applied when the draft is saved, not while
typing. Table-driven tests mirror the official cases ("25" → "2025", "2025" → "2025", "0025" →
"2025", "125" → "2025", "" → nil).

### D4. Pickers in the edit form

`CardEditForm` replaces the three text rows with:
- Brand: `Picker` with "Not set", the ten official entries (display names as on the web), and a
  "<value> (custom)" entry only when D1 returned `.custom`.
- Month: `Picker` with "Not set", "01 - January" … "12 - December", and a custom entry if needed.
- Year: text field with placeholder "YYYY"; free text, normalised on save (D3, D8).

Menu-style pickers inside `DetailSectionCard`, padded with `Spacing.rowVertical` /
`Spacing.rowHorizontal`, labels in `Typography.fieldLabel`. Each picker's accessibility label is
the field name ("Brand", "Expiry month"), and its value is read as the selected display name
(§VIII).

### D5. Detail view expiry

If month and year are both numeric, show "MM / YYYY" (month zero-padded for display only). Otherwise
show the stored values as today. VoiceOver reads "Expires March 2027" for numeric values.

### D6. Blank URI rows are not sent

On save, the draft drops every URI row whose value is empty or whitespace-only **and** that was not
a value-less URI loaded from the server. With `fix-read-mapping-lossless-fields` in place, a
server `uri: null` row is marked as such and kept; without it, such rows don't reach the draft at
all today. The new-login draft keeps one empty row for convenience; it simply isn't sent when left
blank.

**Rejected alternative:** send `uri: null` for a blank row, like the web form. It needs the
optional Domain URI from `fix-read-mapping-lossless-fields` and gives other clients an empty row
anyway. Dropping the row is simpler and shows nothing in every client.

### D7. Only edited content is normalised (added 2026-10-26)

The edit sheet normalises a draft unless the edit changes only folder and/or favorite (the same
test `VaultRepositoryImpl.update` uses to pick `/partial`). Such a change is sent as is, so it stays a `/partial` save, which also works for items in
read-only collections (`org-items-in-personal-folders`). Normalising there would turn it into a
full PUT that the server refuses for such items. A card with brand "visa" is therefore rewritten
the next time anything else is edited, not when it is only moved.

### D8. Year with no usable digits is kept (added 2026-10-26)

The web form turns a year like "n/a" into an empty value. Prizm keeps it, per the goal that no
stored value is lost. Blank years are saved as no value.

## Risks / Trade-offs

- **[Low] Normalising on save changes stored text** ("visa" → "Visa", "03" → "3", "25" → "2025").
  → Same meaning, official format; applied only when the user saves the item.
- **[Low] Detection overrides a manual brand when the number is edited.** → Same as the web form.
- **[Low] Two-digit year in the far future or past** maps to the current century, as official.

- **[Low] Detection follows every number edit**, also after the user picked a brand or when the
  stored brand was a custom one ("Carte Bleue" is replaced on the first matching digit). → Same as
  the web form's number `valueChanges`.
- **[Low] Detail view shows display text.** The brand shows and copies as "American Express", the
  expiry as "03 / 2027". → Chosen for reading; both paste fine into payment forms. Revisit if
  users ask for the stored values.
- **[Info] Value-less server URIs** (`uri: null`) are still dropped on read until
  `fix-read-mapping-lossless-fields` lands; the requirement's second sentence depends on it.

## Open Questions

1. Should the identity title get the official picker in the same change? Kept out to stay small.
