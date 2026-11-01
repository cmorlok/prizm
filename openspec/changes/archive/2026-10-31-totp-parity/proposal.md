# Proposal

## Why

**Criticality:** P3 (Low)
**Findings:** T-01, T-02, T-03 (`05-attachments-totp-icons.md`)

The verification-code feature (unreleased, CHANGELOG "Unreleased") accepts fewer TOTP seeds than
the official Bitwarden apps:

- **Steam seeds (T-01).** `steam://` seeds show "unavailable". Official apps show 5-character Steam
  Guard codes.
- **Strict parsing (T-03).** A seed that official apps accept shows "unavailable" in Prizm when it:
  - contains characters outside base32 (for example dashes),
  - names an unknown `algorithm`,
  - uses `digits` 9 or 10, or 5,
  - has a non-numeric `digits` or `period`.
  Users see a code in the browser extension and "unavailable" in Prizm for the same item.
- **No premium check (T-02).** Official apps show and copy codes only when the user has premium
  (personally or through an organization) or the item's organization has TOTP enabled. Prizm shows
  them always, and keeps doing so (decided 2026-10-30: no server enforces it; design D5).

## Origin of the current behaviour

- **T-03: deliberate, partly on a wrong premise.** `specs/001-totp-verification-codes/research.md:17-18`
  rejects coercion because it "would show wrong codes and break trust". `research.md:16` says the
  parser "Covers what authenticator apps and Bitwarden accept", which is not true for Bitwarden.
- **T-01: known gap.** `specs/001-totp-verification-codes/spec.md:131`: "The Steam-style seed form
  is not supported in this feature".
- **T-02: accidental.** Nothing in `specs/001-totp-verification-codes/` mentions premium.

## What Changes

- **Steam Guard codes** for `steam://<secret>`: HMAC-SHA1, 30 s, 5 characters from
  `23456789BCDFGHJKMNPQRTVWXY`, as the SDK.
- **Lenient parsing like the SDK:** drop non-base32 characters from secrets; unknown algorithm →
  SHA-1; `digits` clamped to 1–10; `period` at least 1; non-numeric values → defaults.
- **Two deliberate differences, recorded:** `otpauth://hotp` links stay "unavailable" (the SDK
  treats them as TOTP, which always gives a wrong code), and a secret with no base32 characters
  stays "unavailable" (the SDK computes a code from an empty key).
- **No entitlement gating** (design D5): codes stay available for every usable seed.
- Correct `research.md` and the spec text (FR-008).

## Capabilities

### New Capabilities
- `totp-seed-compat`: which TOTP seeds Prizm accepts, how Steam codes are generated, and when codes
  are shown.

### Modified Capabilities
_None in this delta._ The feature is specified in Spec Kit format at
`specs/001-totp-verification-codes/` (FR-008 and assumptions); those lines are corrected in tasks
6.1–6.2.

## Non-Goals

- HOTP (counter-based) codes.
- Editing or adding TOTP seeds.
- Showing the raw seed.
- Reproducing the SDK's 10-digit arithmetic, which wraps in `u32` and differs from RFC 4226
  (design D3).

## Dependencies

None.

## Impact

- **Domain:** `TOTPSeedParser` (lenient rules, Steam), `TOTPConfiguration` (Steam alphabet),
  `TOTPCode.grouped` (group only above 4 characters).
- **Data:** `GenerateTOTPCodeUseCaseImpl` (Steam derivation, 64-bit modulus for 9–10 digits).
- **Presentation:** Steam codes grouped "AB CDE" in the code views.
- **No new dependencies.**
- **Security review: no** for parsing and gating (no keys or secrets change hands). HMAC use is
  unchanged except the Steam output mapping; a reviewer should still check that the seed is never
  logged.

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | SDK test vectors, confirm 10-digit behaviour | 0.5 d |
| 2 | Lenient parsing | 1 d |
| 3 | Steam codes | 0.5–1 d |
| 4 | No gating: one test (design D5) | 0.1 d |
| 5 | Spec and docs corrections, CHANGELOG | 0.5 d |
| **Total** | | **2.6–3.1 d** |
