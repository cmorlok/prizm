# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). This change has
no hard dependencies and can ship as a patch release on its own.

## 1. Confirm server behaviour (0.25–0.5 d)

- [ ] 1.1 On the rig (Vaultwarden 1.37.4) and, if available, Bitwarden self-hosted: record in design.md, Context, the exact JSON of `GET /api/organizations/{org}/collections/{id}/details` for a collection with two members and one group, and confirm that a PUT with that body plus a new name leaves access unchanged.
- [x] 1.2 Reproduce today's bug as a fixture-based test: rename with the current code sends `users: []` and `groups: []`. This test is inverted in 3.1.
  Not a separate test: the new tests assert the request contents the old code got wrong (see Results).

## 2. Access-details API (0.5 d)

- [x] 2.1 Failing test: decode a details response (both key casings) into `CollectionAccessDetailsResponse`, including `externalId: null` and missing `groups`.
- [x] 2.2 Implement `getCollectionAccessDetails(organizationId:id:)` and the D4 types in `PrizmAPIClient`. Remove `CollectionBody`.

## 3. Rename keeps access (0.5 d)

- [x] 3.1 Failing test (mock API): `renameCollection` calls the details endpoint first, then sends a PUT whose `users`, `groups` and `externalId` equal the details response and whose `name` decrypts with the org key to the new name.
- [x] 3.2 Failing tests: the details call fails (404, 403, 500, network), and in another case the response lacks `users` → no PUT is sent, the error surfaces, and the local name is unchanged. No code path sends `users: []` for a rename.
- [x] 3.3 Failing test with a Vaultwarden 1.32.0-style details fixture: rename resends it unchanged.
- [x] 3.4 Implement D1 and D2 in `VaultRepositoryImpl.renameCollection`. Replace the comment at `PrizmAPIClient.swift:917` with one that explains why the access list is resent (§VII, link to this change).
- [x] 3.5 The rename error in the sidebar uses the D2 message and is announced to VoiceOver (§VIII). Existing view-model test extended.

## 4. Create assigns the creator (0.5–0.75 d)

- [x] 4.1 Failing test: `RawOrganization` decodes `organizationUserId`; `Organization.membershipId` carries it.
- [x] 4.2 Failing test (mock API): `createCollection` sends the creator with `manage: true`, `readOnly: false`, `hidePasswords: false`, and `groups: []`.
- [x] 4.3 Failing test: `organizationUserId` present but undecodable → no POST, the create error surfaces, no guessed id.
- [x] 4.4 Failing tests for `LegacyCollectionCreateWithoutMembership` (design.md D3): with an official v2024.6.0-style profile (no `organizationUserId`), create sends `users: []`, `groups: []`, `externalId: null`, as today, and logs at `.info`. With `organizationUserId` present, the adapter is not called (spy). Rename never calls it.
- [x] 4.5 Implement D3, with the adapter in `Prizm/Data/Repositories/Legacy/LegacyCollectionCreateWithoutMembership.swift` and the marker `// LEGACY(Bitwarden server < v2025.1.0, no organizationUserId in the profile): remove when those versions are no longer supported`. Add it to the "Legacy adapters" table in `FIX-ORDER.md` if missing.

## 5. Release (0.5 d)

- [ ] 5.1 Live check on Vaultwarden 1.37.4: rename a collection shared with a second account, then confirm in that account's web vault that access is unchanged. Create a collection as admin and as a Manager with access to all collections.
- [x] 5.2 Mandatory security review: access lists are resent unchanged, never invented; no names or ids beyond the collection id in logs.
  Done by the review subagent; see Results.
- [x] 5.3 CHANGELOG "Fixed": renaming a collection no longer removes members' and groups' access; new collections are managed by their creator. Add a note that admins should check the access of collections renamed with earlier Prizm versions.
- [x] 5.4 At archive time, update `openspec/specs/org-collections/spec.md` ("User can rename a collection") to say that the rename resends the current access list.
  The change MODIFIES "User can rename a collection (role-gated)" in `org-collections` (added 2026-10-26).
- [x] 5.5 `openspec validate fix-collection-access-on-rename --type change --strict`.

## Results (2026-10-25)

- `CollectionAccessTests`, `OrganizationMembershipIdTests`, `CollectionRequestWireTests` (fixtures
  from the Vaultwarden 1.37.4 source, a 1.32.0-shaped response, PascalCase). `PrizmTests`: 622 passed.
- 1.2 not written as a separate test: the new tests assert the request contents the old code got
  wrong (empty lists, no `externalId`, no creator).
- 3.4: the comment on the old `CollectionBody` is gone with the type; the reason is documented on
  `CollectionAccess.swift`, the client calls and `VaultRepositoryImpl.renameCollection`.
- 3.5: the rename error reaches the user through the existing `actionError` alert, which
  `VaultBrowserView` announces; `CollectionAccessTests` checks the message, there is no separate
  view-model test.
- 4.3: a present `organizationUserId` that is not a string (including null) is `.unreadable`: create
  is not sent. An organization missing from the cache is treated the same way.
- 4.5: the `FIX-ORDER.md` row for `LegacyCollectionCreateWithoutMembership` is on the change-request
  branch.
- After review: Vaultwarden 1.32.x sends no `manage` (rename failed there); a missing `manage` now
  reads as false (legacy decoder) and the 1.32.0 fixture is corrected. The derived-`manage` effect on
  Vaultwarden is documented as a risk and an open decision. The rename error log carries the HTTP
  status only (the error text holds the response body); the create log no org id;
  `Organization.membershipId` has no default any more. Not tested: the legacy path's `.info` log.
- Open: 1.1 and 5.1 need the rig; 5.2 security review (below); 5.4 at archive time.

## Verification (2026-10-26, `/opsx:verify`)

- No code gaps. Proposal and design D3 now name `OrgMembershipId` instead of `String?`.
- The legacy adapter's `.info` log (task 4.4) has no test: `os.Logger` output cannot be read in
  XCTest. The adapter's behaviour is tested.
- Open by design: 1.1 and 5.1 (test server).
- Second round (2026-10-26): the old comment "`groups` and `users` default to empty" was still above
  `createCollection` (3.4 was ticked, but only the type was gone); removed. The protocol docs now
  describe `request` instead of a removed `encryptedName` parameter, and the PUT line sits on
  `renameCollection`.

