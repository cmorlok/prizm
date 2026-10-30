# lossless-item-fields Specification

## Purpose
Data that Prizm reads into its model is written back unchanged unless the user edits it: custom
fields without a name, websites without an address, and field types, linked fields and match rules
that Prizm does not know.

## Requirements

### Requirement: Custom fields without a name survive an edit
The system SHALL keep a custom field whose `name` is null when reading an item, SHALL show it with the label "Unnamed field", and SHALL send it back with `name` null when the item is saved, unless the user changed that field.

#### Scenario: Editing an item with a nameless custom field
- **GIVEN** an item with a custom field whose `name` is null and whose value is "abc"
- **WHEN** the user changes only the item's username and saves
- **THEN** the update request SHALL contain that custom field with `name` null and a value that decrypts to "abc"
- **AND** the field SHALL keep its position in the `fields` list

#### Scenario: Viewing a nameless custom field
- **GIVEN** an item with a custom field whose `name` is null
- **WHEN** the user opens the item
- **THEN** the field SHALL be shown with the label "Unnamed field"
- **AND** VoiceOver SHALL read "Unnamed field" followed by the value

### Requirement: Login URIs without a value survive an edit
The system SHALL keep a login URI whose `uri` is null when reading an item, SHALL NOT show it in the item detail, and SHALL send it back with `uri` null and its original `match` value when the item is saved, unless the user filled in or removed that row.

#### Scenario: Editing a login with a value-less URI
- **GIVEN** a login with two URIs, the first with `uri` null and `match` 3, the second "https://example.com"
- **WHEN** the user changes only the password and saves
- **THEN** the update request SHALL contain both URIs in the same order
- **AND** the first SHALL have `uri` null and `match` 3

#### Scenario: Filling in a value-less URI
- **GIVEN** the edit form shows an empty website row for a URI whose `uri` is null
- **WHEN** the user types "https://new.example" into that row and saves
- **THEN** the update request SHALL contain that URI encrypted, with its original `match` value

### Requirement: Unknown field types, linked ids and match rules are kept unchanged
The system SHALL keep the original integer of a custom field `type`, a `linkedId` or a URI `match` value it does not recognise, SHALL show the value as unsupported and read-only, and SHALL send the original integer back when the item is saved.

#### Scenario: Unknown custom field type
- **GIVEN** an item with a custom field of `type` 9 and a value
- **WHEN** the user opens the item
- **THEN** the field SHALL be labelled "Unsupported field type" and its value SHALL NOT be editable
- **WHEN** the user changes another field and saves
- **THEN** the update request SHALL contain that field with `type` 9 and its original value

#### Scenario: Unknown linked field target
- **GIVEN** an item with a linked custom field whose `linkedId` is 999
- **WHEN** the user saves an unrelated change
- **THEN** the update request SHALL contain that field with `type` 3 and `linkedId` 999

#### Scenario: Unknown URI match rule
- **GIVEN** a login URI with `match` 7
- **WHEN** the user saves an unrelated change
- **THEN** the update request SHALL contain that URI with `match` 7
