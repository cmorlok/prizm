# collection-access-preservation Specification

## Purpose
Keep a collection's member and group access when it is renamed, and give its creator access.

## Requirements

### Requirement: Renaming a collection keeps its access settings
When the user renames a collection, the system SHALL first read the collection's current access with `GET /api/organizations/{orgId}/collections/{id}/details` and SHALL send the same `users`, `groups` and `externalId`, with every `readOnly`, `hidePasswords` and `manage` flag unchanged, together with the new encrypted name in `PUT /api/organizations/{orgId}/collections/{id}`.

#### Scenario: Rename a collection shared with members and a group
- **GIVEN** a collection assigned to member A with Manage, member B as read-only, group G with hide-passwords, and `externalId` "ext-42"
- **WHEN** the user renames the collection to "Infrastructure"
- **THEN** the PUT body SHALL contain member A with `manage: true`, member B with `readOnly: true`, group G with `hidePasswords: true`, and `externalId` "ext-42"
- **AND** after the next sync member B SHALL still see the collection and its items

#### Scenario: Rename on Vaultwarden
- **GIVEN** a Vaultwarden server from 1.32.0 to 1.37.4 and a collection assigned to two members
- **WHEN** the user renames the collection
- **THEN** the request SHALL succeed
- **AND** both members SHALL keep their access

### Requirement: A rename never sends an access list it did not read
If the current access list cannot be read, the system SHALL NOT send the rename request, SHALL keep the old name, and SHALL show an error. The system SHALL NOT send an empty or invented access list for a rename on any server.

#### Scenario: Details request fails
- **GIVEN** the details request returns an error
- **WHEN** the user commits a new collection name
- **THEN** no PUT request SHALL be sent
- **AND** the collection SHALL keep its previous name
- **AND** the user SHALL see "Couldn't rename the collection. Its access settings could not be read."

### Requirement: A new collection is managed by its creator
When the user creates a collection, the system SHALL send the current member's organization-user id in `users` with `manage: true`, `readOnly: false` and `hidePasswords: false`.

#### Scenario: Create a collection
- **GIVEN** the user is a member of an organization with organization-user id "ou-1"
- **WHEN** the user creates the collection "Ops"
- **THEN** the POST body SHALL contain `users: [{id: "ou-1", readOnly: false, hidePasswords: false, manage: true}]`
- **AND** after the next sync the collection SHALL still be listed in the user's sidebar

#### Scenario: Create on a server without organizationUserId
- **GIVEN** an official server before v2025.1.0 whose sync profile has no `organizationUserId`
- **WHEN** the user creates the collection "Ops"
- **THEN** the system SHALL send the request it sends today, with `users: []` and `groups: []`, through the legacy create adapter
- **AND** the legacy adapter SHALL NOT be used when the profile has `organizationUserId`
