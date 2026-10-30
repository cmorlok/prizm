## MODIFIED Requirements

### Requirement: Organization symmetric keys are unwrapped at sync time
For each organization in the sync response, the system SHALL unwrap the organization's symmetric key from a one-part EncString of type 4 with RSA-OAEP-SHA1 (`SecKeyCreateDecryptedData`) and the user's in-memory RSA private key, and SHALL accept only a 64-byte result. Any other type or form SHALL be rejected before any RSA operation. Unwrapped keys SHALL be stored in `OrgKeyCache` by `organizationId` and zeroed on removal (Constitution §III).

#### Scenario: Org key unwrapped and cached at sync
- **WHEN** a sync response containing one or more organizations with type-4 keys is processed
- **THEN** each organization's symmetric key SHALL be unwrapped and stored in `OrgKeyCache`

#### Scenario: Failed org key unwrap is logged and skipped
- **GIVEN** an organization's key EncString is of type 3, 5 or 6, is otherwise malformed, or the RSA operation fails
- **WHEN** sync processes that organization
- **THEN** an `.error` log entry naming the error (for types 3, 5 and 6 the type number) and no key material SHALL be emitted
- **AND** no RSA operation SHALL be attempted for types 3, 5 and 6
- **AND** that organization SHALL NOT be listed, and its items SHALL be skipped and counted as failed

#### Scenario: OrgKeyCache cleared on vault lock
- **WHEN** the vault is locked
- **THEN** `OrgKeyCache` SHALL be cleared alongside `VaultKeyCache`
