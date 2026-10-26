## MODIFIED Requirements

### Requirement: User can rename a collection (role-gated)
Right-clicking a collection row SHALL show a context menu with "Rename" (only if `canManageCollections == true` for that org). Selecting Rename SHALL activate inline editing. Committing a non-empty name SHALL read the collection's current access (`GET /organizations/{orgId}/collections/{id}/details`), encrypt the name with the org key, and call `PUT /organizations/{orgId}/collections/{id}` with the member and group access unchanged (see `collection-access-preservation`).

#### Scenario: Rename available for admin role
- **GIVEN** the user has role Admin or Owner in the org
- **WHEN** the user right-clicks a collection
- **THEN** a "Rename" option SHALL appear in the context menu

#### Scenario: Rename not available for user role
- **GIVEN** the user has role User in the org
- **WHEN** the user right-clicks a collection
- **THEN** no "Rename" option SHALL appear

#### Scenario: Commit rename updates collection name
- **GIVEN** the user is renaming a collection to "Infrastructure"
- **WHEN** the user presses Enter
- **THEN** the name SHALL be encrypted and sent via `PUT /organizations/{orgId}/collections/{id}`
- **AND** the request SHALL carry the collection's current member and group access
- **AND** the collection SHALL re-sort alphabetically

#### Scenario: Server error during collection rename
- **GIVEN** the user commits a valid new collection name
- **WHEN** the server returns an error
- **THEN** the collection name SHALL revert to its previous value and an error alert SHALL be shown
