# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
**Prerequisite:** `fix-cipher-edit-data-loss` and `fix-org-attachment-key` are merged (keyed read,
effective-key write, `encryptedFor`, key source recorded on create).

## 1. Confirm wire details (0.5 d)

- [ ] 1.1 Record in design.md, Risks, the oldest official client that reads keyed items (the server versions are already in D5).
- [ ] 1.2 Failing test: create a personal and an org item, then ask `VaultKeyService` for the item's key before any sync. It must be the generated item key (today: the vault or org key). Regression guard for D4; it passes after 3.4.

## 2. Key helpers (0.5 d)

- [ ] 2.1 `generateSymmetricKey()` (renamed from `generateAttachmentKey`): 64 bytes from `SecRandomCopyBytes`, buffer zeroed. Tests: length, two calls differ.
- [ ] 2.2 Round trip: wrap with `EncString.encrypt` under the vault key and an org key, unwrap through `effectiveKeys`. Known-answer only for unwrapping an SDK-produced item key (reuse the existing vector from `fix-cipher-edit-data-loss` if present).

## 3. Create with own key (0.5–1 d)

- [ ] 3.1 Failing test: personal create of each of the five types. The request has `key`; `key` unwraps with the vault key; every encrypted field (login incl. `uriChecksum`, card, identity, SSH key incl. `keyFingerprint`, notes, custom field names and values) decrypts with the item key and fails with the vault key. `create()` never sends a request without `key`.
- [ ] 3.2 Failing test: org create. Same assertions, with the org key as wrapping key.
- [ ] 3.3 Failing tests: missing org key (`organizationKeyUnavailable`) and failing key generation (`itemKeyGenerationFailed`, with its text). No request is sent, and the create sheet stays open with the input.
- [ ] 3.5 Failing tests (design D4): the answer has no `key`, or a `key` that unwraps to other bytes. Nothing is stored, cached or listed; `createdButUnconfirmed` is thrown; the view model shows its text and keeps Save disabled. A lock while the request runs records nothing (`whileCreatingCipher`).
- [ ] 3.6 Rename `toNewRawCipher` to `toUnkeyedRawCipher` (fixtures and tests only) and rewrite its doc comment ("never a create path").
- [ ] 3.4 Implement D1–D3 in `VaultRepositoryImpl.create` and `CipherMapper.toNewKeyedRawCipher`. §VII comments on key generation and selection.

## 4. Cache on create (0.5 d)

- [ ] 4.1 Attachment file name and key on an item created before any sync are encrypted with the item key: `VaultKeyService` returns the generated item key right after the create (repository test); attachment uploads take their key only from that service (`fix-org-attachment-key`), so no separate upload test.
- [ ] 4.2 Confirm the existing tests for the cache-miss rule (`VaultKeyServiceImplTests`, unknown ciphers throw) and for create after lock (`OrgAttachmentKeyTests.testCreateFinishingAfterALock_recordsNoKeySource`) still pass.

## 5. Release (0.5 d)

- [ ] 5.1 Interop check on the rig (Vaultwarden 1.37.4): create a personal login (`POST /api/ciphers`) and an org login (`POST /api/ciphers/create`, `{cipher:{…key…}, collectionIds}`) with an attachment in Prizm; the stored records carry `key`; the official `bw` CLI (record its SDK build) reads both and the attachments; edit one with `bw` and confirm it still opens in Prizm. The web-vault UI is a documented gap (`bw` stands in).
- [ ] 5.2 Mandatory security review: random source, key wrapping, no key bytes in logs, zeroing.
- [ ] 5.3 CHANGELOG "Changed": new items are created with their own encryption key, as in official Bitwarden apps. CHANGELOG "Fixed": attachments added to a new organization item before the next sync are encrypted for the organization.
- [ ] 5.4 `openspec validate per-item-key-on-create --type change --strict`.
