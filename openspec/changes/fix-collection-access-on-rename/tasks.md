# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). This change has
no hard dependencies and can ship as a patch release on its own.

## 1. Confirm server behaviour (0.25–0.5 d)

- [ ] 1.1 On the rig (Vaultwarden 1.37.4) and, if available, Bitwarden self-hosted: record in design.md, Context, the exact JSON of `GET /api/organizations/{org}/collections/{id}/details` for a collection with two members and one group, and confirm that a PUT with that body plus a new name leaves access unchanged.
- [ ] 1.2 Reproduce today's bug as a fixture-based test: rename with the current code sends `users: []` and `groups: []`. This test is inverted in 3.1.

## 2. Access-details API (0.5 d)

- [ ] 2.1 Failing test: decode a details response (both key casings) into `CollectionAccessDetailsResponse`, including `externalId: null` and missing `groups`.
- [ ] 2.2 Implement `getCollectionAccessDetails(organizationId:id:)` and the D4 types in `PrizmAPIClient`. Remove `CollectionBody`.

## 3. Rename keeps access (0.5 d)

- [ ] 3.1 Failing test (mock API): `renameCollection` calls the details endpoint first, then sends a PUT whose `users`, `groups` and `externalId` equal the details response and whose `name` decrypts with the org key to the new name.
- [ ] 3.2 Failing tests: the details call fails (404, 403, 500, network), and in another case the response lacks `users` → no PUT is sent, the error surfaces, and the local name is unchanged. No code path sends `users: []` for a rename.
- [ ] 3.3 Failing test with a Vaultwarden 1.32.0-style details fixture: rename resends it unchanged.
- [ ] 3.4 Implement D1 and D2 in `VaultRepositoryImpl.renameCollection`. Replace the comment at `PrizmAPIClient.swift:917` with one that explains why the access list is resent (§VII, link to this change).
- [ ] 3.5 The rename error in the sidebar uses the D2 message and is announced to VoiceOver (§VIII). Existing view-model test extended.

## 4. Create assigns the creator (0.5–0.75 d)

- [ ] 4.1 Failing test: `RawOrganization` decodes `organizationUserId`; `Organization.membershipId` carries it.
- [ ] 4.2 Failing test (mock API): `createCollection` sends the creator with `manage: true`, `readOnly: false`, `hidePasswords: false`, and `groups: []`.
- [ ] 4.3 Failing test: `organizationUserId` present but undecodable → no POST, the create error surfaces, no guessed id.
- [ ] 4.4 Failing tests for `LegacyCollectionCreateWithoutMembership` (design.md D3): with an official v2024.6.0-style profile (no `organizationUserId`), create sends `users: []`, `groups: []`, `externalId: null`, as today, and logs at `.info`. With `organizationUserId` present, the adapter is not called (spy). Rename never calls it.
- [ ] 4.5 Implement D3, with the adapter in `Prizm/Data/Repositories/Legacy/LegacyCollectionCreateWithoutMembership.swift` and the marker `// LEGACY(Bitwarden server < v2025.1.0, no organizationUserId in the profile): remove when those versions are no longer supported`. Add it to the "Legacy adapters" table in `FIX-ORDER.md` if missing.

## 5. Release (0.5 d)

- [ ] 5.1 Live check on Vaultwarden 1.37.4: rename a collection shared with a second account, then confirm in that account's web vault that access is unchanged. Create a collection as admin and as a Manager with access to all collections.
- [ ] 5.2 Mandatory security review: access lists are resent unchanged, never invented; no names or ids beyond the collection id in logs.
- [ ] 5.3 CHANGELOG "Fixed": renaming a collection no longer removes members' and groups' access; new collections are managed by their creator. Add a note that admins should check the access of collections renamed with earlier Prizm versions.
- [ ] 5.4 At archive time, update `openspec/specs/org-collections/spec.md` ("User can rename a collection") to say that the rename resends the current access list.
- [ ] 5.5 `openspec validate fix-collection-access-on-rename --type change --strict`.
