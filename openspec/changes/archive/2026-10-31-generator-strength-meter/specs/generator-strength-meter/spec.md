## ADDED Requirements

### Requirement: The generator shows the strength of its settings
The password generator SHALL show the entropy of the value it generates, computed from the current settings, as a colored bar and a label naming the category and the bits rounded down: Weak below 64 bits (red), OK from 64 to below 80 bits (orange to yellow), Strong from 80 to below 128 bits (green), Very strong from 128 bits (green).

#### Scenario: Default password
- **GIVEN** password mode with length 16 and uppercase, lowercase, digits and special characters on
- **WHEN** the generator opens
- **THEN** the meter SHALL show "Strong · 97 bits"

#### Scenario: Short password
- **GIVEN** password mode with length 8 and uppercase, lowercase, digits and special characters on
- **THEN** the meter SHALL show "Weak · 47 bits" in red

#### Scenario: Six-word passphrase
- **GIVEN** passphrase mode with 6 words and no number
- **THEN** the meter SHALL show "OK · 77 bits"

#### Scenario: Very strong
- **GIVEN** password mode with length 24 and every set on, including extended special
- **THEN** the meter SHALL show "Very strong · 155 bits" with a full bar

#### Scenario: High minimums
- **GIVEN** password mode with length 12, all four standard sets on and at least 9 numbers
- **THEN** the meter SHALL show "Weak · 52 bits", counting only the passwords those settings allow

#### Scenario: Settings change
- **GIVEN** the meter shows a strength
- **WHEN** the user changes the length, a set, the word count or the number option
- **THEN** the meter SHALL show the strength of the new settings

#### Scenario: Generator error
- **GIVEN** the generator shows an error instead of a value
- **THEN** no meter SHALL be shown

### Requirement: The strength is readable without color
The meter SHALL expose one accessibility element labelled "Strength" whose value names the category and the bits, and SHALL never convey the category by color alone.

#### Scenario: VoiceOver
- **WHEN** VoiceOver reaches the meter for the default password
- **THEN** it SHALL read "Strength, Strong, 97 bits"
