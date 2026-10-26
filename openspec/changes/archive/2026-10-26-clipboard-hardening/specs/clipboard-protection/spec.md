# Spec Delta

## ADDED Requirements

### Requirement: Every copy is concealed and cleared independently of the view
Every value the system copies, including from the password generator, SHALL be written with the `org.nspasteboard.ConcealedType` marker and SHALL be cleared after the configured delay if the clipboard has not changed since, even if the view or sheet that copied it has closed.

#### Scenario: Generator copy after the sheet closes
- **GIVEN** the clear delay is 30 seconds
- **WHEN** the user copies a generated password, uses it and saves, closing the edit sheet
- **THEN** after 30 seconds the clipboard SHALL be empty

#### Scenario: Generator copy is concealed
- **WHEN** the user copies a generated password
- **THEN** the pasteboard SHALL contain the `org.nspasteboard.ConcealedType` type

#### Scenario: User copied something else
- **GIVEN** Prizm copied a password
- **WHEN** the user copies other text in another app before the delay ends
- **THEN** Prizm SHALL NOT clear the clipboard

### Requirement: The clear delay is configurable
The Settings window SHALL offer a clipboard clear delay of Never, 10 seconds, 20 seconds, 30 seconds, 1 minute, 2 minutes or 5 minutes. The default SHALL be 30 seconds.

#### Scenario: Two-minute delay
- **GIVEN** the clear delay is 2 minutes
- **WHEN** the user copies a password
- **THEN** the clipboard SHALL still hold it after 1 minute
- **AND** SHALL be cleared after 2 minutes

### Requirement: The clipboard is cleared when the session ends
When the vault locks, the user signs out, or Prizm quits normally, the system SHALL clear the clipboard if it still holds the last value Prizm copied, whatever the delay setting.

#### Scenario: Lock right after a copy
- **GIVEN** the user copied a password 5 seconds ago
- **WHEN** the user presses ⌘L
- **THEN** the clipboard SHALL be empty

#### Scenario: Quit with a foreign clipboard value
- **GIVEN** the user copied text in another app after Prizm's last copy
- **WHEN** the user quits Prizm
- **THEN** the clipboard SHALL still hold that text
