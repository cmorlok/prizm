# ssh-key-integrity Specification

## Purpose
Keep an SSH key item's private key, public key and fingerprint complete and consistent on every
write, so no server hides the key and no client gets a fingerprint that describes another key.

## Requirements

### Requirement: Editing an SSH key item keeps its fingerprint
When the user saves an SSH key item, the system SHALL send its existing key fingerprint, encrypted with the same key as the item's other fields, together with the unchanged private and public key.

#### Scenario: Rename an SSH key on Vaultwarden
- **GIVEN** an SSH key item created in the Bitwarden web vault, stored on Vaultwarden 1.37.4
- **WHEN** the user changes only its name in Prizm and saves
- **THEN** the update request SHALL contain `keyFingerprint`, `privateKey` and `publicKey`
- **AND** after the next sync the web vault SHALL show the same private key, public key and fingerprint

### Requirement: SSH key fields are read-only in the edit sheet
The edit sheet SHALL show the private key (masked, with reveal and copy), the public key and the fingerprint of an SSH key item as read-only values with copy, each with a VoiceOver label. Name, notes and custom fields SHALL stay editable.

#### Scenario: Open the edit sheet of an SSH key
- **GIVEN** an SSH key item
- **WHEN** the user opens the edit sheet
- **THEN** the private key, public key and fingerprint SHALL NOT be editable
- **AND** VoiceOver SHALL read the label "Public Key" and its value, and SHALL NOT announce a text field

### Requirement: SSH items without key data are not editable
When an SSH key item has no private key or no public key, the system SHALL disable every Edit action for it and SHALL explain "This SSH key is incomplete and can't be edited in Prizm. Open it in a Bitwarden app to repair it." The system SHALL NOT send a full update for such an item.

#### Scenario: Key hidden by Vaultwarden
- **GIVEN** Vaultwarden returns an SSH key item with `sshKey: null`
- **WHEN** the user selects the item
- **THEN** Edit SHALL be disabled with the explanation above
- **AND** favorite, move to folder and delete SHALL stay available

### Requirement: SSH keys cannot be created until Prizm can generate or import them
The New Item menu SHALL NOT offer "SSH Key". The system SHALL NOT send a create request for an SSH key item.

#### Scenario: New Item menu
- **WHEN** the user opens the New Item menu
- **THEN** Login, Card, Identity and Secure Note SHALL be offered
- **AND** SSH Key SHALL NOT be offered

#### Scenario: Existing SSH keys still listed
- **GIVEN** the vault contains SSH key items
- **WHEN** the user selects "SSH Key" in the sidebar Types section
- **THEN** those items SHALL be listed as before
