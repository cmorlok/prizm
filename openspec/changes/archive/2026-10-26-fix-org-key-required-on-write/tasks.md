# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies. If `fix-cipher-edit-data-loss` lands first and already implements KEY-03 in
`update()`, task 1.3 reduces to wiring `create()` and keeping the tests.

## 1. No fallback on write (0.5 d)

- [x] 1.1 Failing test (mock API, empty `OrgKeyCache`): `update()` of an org draft throws `VaultError.organizationKeyUnavailable` and the mock API records no request. Today it sends a PUT encrypted with the vault key.
- [x] 1.2 Failing test: the same for `create()`.
- [x] 1.3 Implement the D1 helper and use it in `create()` and `update()` (`VaultRepositoryImpl.swift:274-280`, `:325-331`). §VII security comment as in design D1.
- [x] 1.4 Regression guards: personal item with no org keys still saves with the vault key; org item with its key still saves with the org key (decrypt the request body with each key in the test).

## 2. Atomic key swap (0.5–0.75 d)

- [x] 2.1 Failing test: `OrgKeyCache.replaceAll(with:)` replaces the map in one call and zeroes the replaced key bytes; a snapshot taken before still holds its own copy.
- [x] 2.2 Failing test: a sync whose org-key unwrap is slowed down (test double) never exposes an empty snapshot to a concurrent reader. Use a reader task that snapshots in a loop while the sync runs.
- [x] 2.3 Failing test: a sync that throws after the profile is loaded but before the swap leaves the previous keys in place.
- [x] 2.4 Failing test: an org missing from a successful sync has no key afterwards.
- [x] 2.5 Implement D2 in `OrgKeyCache` and `SyncRepositoryImpl.swift:148-160`. Extract the zeroing code shared with `clear()`.

## 3. User-facing error (0.25 d)

- [x] 3.1 Failing view-model test: `ItemEditViewModel` maps `.organizationKeyUnavailable` to the D3 message, keeps the draft and announces it (§VIII).
- [x] 3.2 Implement the `VaultError` case and its `errorDescription`.

## 4. Release (0.25–0.5 d)

- [x] 4.1 Mandatory security review: no write path can pick the vault key for an org item; key bytes zeroed on swap; nothing secret in logs.
  Passed; see Results.
- [x] 4.2 State the overlap in `fix-cipher-edit-data-loss` (KEY-03) and `per-item-key-on-create` (D2) when either is next edited: both refer to this change's rule.
  Checked 2026-10-29: the design of `fix-cipher-edit-data-loss` names the rule `fix-org-key-required-on-write` (key selection and the active key), and so does the design of `per-item-key-on-create` (still a change request on `spec/autofill-passkeys-change-requests`).
- [x] 4.3 CHANGELOG "Fixed": organization items can no longer be saved with your personal key while a sync is running or when the organization key is unavailable; such saves now show an error. Add how to recover an item that became unreadable: open it in an official Bitwarden app as the user who saved it and save it again.
- [x] 4.4 `openspec validate fix-org-key-required-on-write --type change --strict`.

## Results (2026-10-25)

- `OrgKeyWriteGuardTests`, `OrgKeyCacheReplaceAllTests`, `SyncOrgKeySwapTests`,
  `ItemEditOrgKeyErrorTests`. With the old fallback and the old `clear()` restored, the guard,
  concurrent-reader and left-org tests fail; with the change they pass. `PrizmTests`: 606 passed.
- 2.3 passes with the old code too (it cleared only after decrypting the private key); kept as a
  regression guard.
- Beyond the tasks: a sync without organizations (or without a private key) skipped the org block,
  so the keys of orgs the user had left stayed; it now replaces them with an empty map.
- The edit sheet's error banner was not announced to VoiceOver; it is now (all save errors).
- 2.1: the zeroing of replaced keys is not observable from outside; the test checks that an earlier
  snapshot keeps its own copy, as the existing `clear()` tests do.
- Security review (4.1): passed; no write path picks the vault key for an org item (attachments'
  `VaultKeyServiceImpl.cipherKey(for:)` fallback is the known non-goal). Fixed after review:
  sign-out did not clear `OrgKeyCache` (only lock did; older than this change, but the design relied
  on it); the message named "Sync", which Prizm has no command for (now "Lock and unlock Prizm");
  the concurrent-reader test now proves the reader ran; a stale doc comment.
- Partly verified: 2.1 "zeroes" (not observable, see above); 3.1 "announces" is in the view
  (`ItemEditView` `onChange(of: saveError)`) and not unit-tested.
- Open: 4.1 done; 4.2 when `fix-cipher-edit-data-loss` or
  `per-item-key-on-create` is next edited.
- Follow-up (2026-10-26): an organization whose key could not be unwrapped is not listed, so the
  create sheet no longer offers it (`SyncOrgKeySwapTests.testSync_orgWhoseKeyFails_isNotListed`).
