# totp-seed-compat Specification

## Purpose
Prizm reads verification-code seeds the way the Bitwarden SDK does, including Steam Guard seeds, so a seed that shows a code in the official apps shows the same code in Prizm; the few recorded differences show "unavailable" instead of a code that can never be right.

## Requirements

### Requirement: TOTP seeds are parsed as leniently as official apps
The system SHALL accept a TOTP seed in the same forms as the Bitwarden SDK: characters outside the base32 alphabet SHALL be ignored, an unknown `algorithm` SHALL mean SHA-1, `digits` SHALL be clamped to at most 10, `period` SHALL be at least 1, a `digits` or `period` that is not an unsigned 32-bit number SHALL fall back to 6 or 30, a key given twice SHALL take its last value, and a string that starts with neither `otpauth://` nor `steam://` SHALL be used as a plain secret.

#### Scenario: Secret with dashes
- **GIVEN** a login whose seed is `JBSW-Y3DP-EHPK-3PXP`
- **WHEN** the user views the item
- **THEN** Prizm SHALL show the same code as for the seed `JBSWY3DPEHPK3PXP`

#### Scenario: Unknown algorithm and 9 digits
- **GIVEN** a seed `otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=MD5&digits=9`
- **WHEN** the user views the item
- **THEN** Prizm SHALL show a 9-digit code computed with HMAC-SHA1

#### Scenario: Negative digits
- **GIVEN** a seed `otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=-1`
- **WHEN** the user views the item
- **THEN** Prizm SHALL show a 6-digit code

#### Scenario: Label with a space and a repeated secret
- **GIVEN** a seed `otpauth://totp/ACME Co:me?secret=AAAAAAAA&secret=JBSWY3DPEHPK3PXP`
- **WHEN** the user views the item
- **THEN** Prizm SHALL show the same code as for the seed `JBSWY3DPEHPK3PXP`

#### Scenario: Other scheme as plain secret
- **GIVEN** a seed `https://example.com`
- **WHEN** the user views the item
- **THEN** Prizm SHALL show the code for the secret made of its base32 characters, as the SDK does

#### Scenario: Non-numeric period
- **GIVEN** a seed `otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=abc`
- **WHEN** the user views the item
- **THEN** Prizm SHALL show a code with a 30-second period

### Requirement: Steam Guard codes
For a seed `steam://<secret>`, the system SHALL show a 5-character code computed with HMAC-SHA1 over a 30-second counter and mapped to the alphabet `23456789BCDFGHJKMNPQRTVWXY` as the Bitwarden SDK does.

#### Scenario: Steam seed
- **GIVEN** a login whose seed is `steam://HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ`
- **WHEN** the user views the item at 2023-01-01T00:00:00Z
- **THEN** Prizm SHALL show "7W 6CJ"
- **AND** copying SHALL put "7W6CJ" on the clipboard

### Requirement: Seeds that can never give a valid code stay unavailable
The system SHALL show "unavailable" for `otpauth://hotp` links, for secrets that decode to zero bytes (fewer than 8 bits of base32), for an `otpauth://` link without `secret`, and for `digits=0`.

#### Scenario: HOTP link
- **GIVEN** a seed `otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1`
- **WHEN** the user views the item
- **THEN** Prizm SHALL show "unavailable" and no code

#### Scenario: Secret too short
- **GIVEN** a seed `A`, or `steam://` with nothing after it
- **WHEN** the user views the item
- **THEN** Prizm SHALL show "unavailable" and no code

#### Scenario: Missing secret
- **GIVEN** a seed `otpauth://totp/x?digits=6`
- **WHEN** the user views the item
- **THEN** Prizm SHALL show "unavailable" and no code

### Requirement: Codes are grouped as in official apps
The system SHALL split a code into two groups at half its length, rounded down, only when it is longer than 4 characters, and SHALL copy it without the space.

#### Scenario: Short and long codes
- **GIVEN** seeds with `digits=4` and `digits=10`
- **WHEN** the user views them
- **THEN** the 4-digit code SHALL be shown unsplit and the 10-digit code as two groups of 5

### Requirement: Codes are not gated on entitlements
The system SHALL show and allow copying a verification code for every item with a usable seed, whatever the account's premium status or the organization's TOTP setting, because no server enforces either for codes, which are computed on the device.

#### Scenario: Account without premium
- **GIVEN** a profile with `premium` and `premiumFromOrganization` false and a personal login with a TOTP seed
- **WHEN** the user views the item, opens Verification Codes, or presses ⌃⌘C
- **THEN** the code SHALL be shown and copied
