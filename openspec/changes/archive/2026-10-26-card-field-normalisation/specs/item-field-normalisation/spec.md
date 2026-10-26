# Spec Delta

## ADDED Requirements

### Requirement: Card brand uses the official values
The card edit form SHALL offer the brand as a picker with "Not set" and the values Visa, Mastercard, American Express (stored as "Amex"), Discover, Diners Club, JCB, Maestro, UnionPay, RuPay and Other. A stored brand that matches one of these values case-insensitively SHALL be shown and saved as that value. Any other stored brand SHALL be shown as "<value> (custom)" and saved unchanged unless the user picks another value.

#### Scenario: Lower-case brand from an earlier Prizm version
- **GIVEN** a card with brand "visa"
- **WHEN** the user changes the cardholder name and saves
- **THEN** the brand SHALL be saved as "Visa"

#### Scenario: Unknown brand is kept
- **GIVEN** a card with brand "Carte Bleue"
- **WHEN** the user edits the cardholder name and saves
- **THEN** the brand SHALL still be "Carte Bleue"

### Requirement: Card brand is detected from the number
When the user changes the card number and it matches a known brand pattern of the official clients, the system SHALL set the brand picker to that brand.

#### Scenario: Typing an Amex number
- **WHEN** the user enters a card number starting with "37"
- **THEN** the brand picker SHALL show "American Express"
- **AND** the saved brand SHALL be "Amex"

### Requirement: Expiry month and year use the official format
The system SHALL save the expiry month as "1" to "12" without a leading zero, chosen from a picker labelled "01 - January" to "12 - December". It SHALL save the expiry year as four digits, normalised with the official rule, so that "25" becomes "2025".

#### Scenario: Month with leading zero
- **GIVEN** a card with expiry month "03"
- **WHEN** the user saves the card
- **THEN** the month SHALL be saved as "3"

#### Scenario: Two-digit year
- **WHEN** the user enters expiry year "27" and saves in the year 2026
- **THEN** the year SHALL be saved as "2027"

#### Scenario: Detail view
- **GIVEN** a card with month "3" and year "2027"
- **WHEN** the card is shown in the detail view
- **THEN** the expiry SHALL read "03 / 2027"

### Requirement: Blank URI rows are not saved
When saving a login, the system SHALL NOT send URI rows that the user left empty or filled only with whitespace. Value-less URIs loaded from the server SHALL be kept once the read path keeps them (`fix-read-mapping-lossless-fields`; until then Prizm drops them when reading).

#### Scenario: New login without a website
- **GIVEN** the user creates a login and leaves the website row empty
- **WHEN** the user saves
- **THEN** the create request SHALL contain no URI

#### Scenario: One filled and one blank row
- **GIVEN** a login with website rows "https://example.com" and an empty row
- **WHEN** the user saves
- **THEN** only "https://example.com" SHALL be sent
