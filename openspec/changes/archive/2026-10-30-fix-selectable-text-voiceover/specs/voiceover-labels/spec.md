# Spec Delta

## MODIFIED Requirements

### Requirement: Displayed values SHALL be the values VoiceOver reads
A text that shows a vault value, a masked value or a generated value SHALL expose the text currently shown, both as its accessibility value and as its text (its number of characters and its text for a range), including after the text changes without the view being recreated.

#### Scenario: Revealed password
- **GIVEN** a password field is masked
- **WHEN** the user clicks Reveal
- **THEN** VoiceOver SHALL read the password, not the mask characters
- **AND** after Hide, it SHALL read the mask again, and the password SHALL NOT remain in the text's character data

#### Scenario: Switching items
- **GIVEN** an item's username and website are shown
- **WHEN** the user selects another item
- **THEN** VoiceOver SHALL read the new item's username and website, by value and by text range

#### Scenario: Edited value
- **GIVEN** an item's note is shown and VoiceOver has read it
- **WHEN** the note is edited and saved
- **THEN** VoiceOver SHALL read the new note, never the old one

#### Scenario: Generator preview
- **WHEN** the generator produces a new value
- **THEN** VoiceOver SHALL read the new value in the preview, by value and by text range
