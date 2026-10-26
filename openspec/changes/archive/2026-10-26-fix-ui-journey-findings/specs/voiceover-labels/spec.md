# Spec Delta

## ADDED Requirements

### Requirement: Displayed values SHALL be the values VoiceOver reads
A text that shows a vault value, a masked value or a generated value SHALL expose the text currently shown as its accessibility value, including after it changes without the view being recreated.

#### Scenario: Revealed password
- **GIVEN** a password field is masked
- **WHEN** the user clicks Reveal
- **THEN** VoiceOver SHALL read the password, not the mask characters
- **AND** after Hide, it SHALL read the mask again

#### Scenario: Switching items
- **GIVEN** an item's username is shown
- **WHEN** the user selects another item
- **THEN** VoiceOver SHALL read the new item's username

#### Scenario: Generator preview
- **WHEN** the generator produces a new value
- **THEN** VoiceOver SHALL read the new value in the preview
