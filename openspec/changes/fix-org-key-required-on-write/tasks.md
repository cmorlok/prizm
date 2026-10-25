# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). No hard
dependencies. If `fix-cipher-edit-data-loss` lands first and already implements KEY-03 in
`update()`, task 1.3 reduces to wiring `create()` and keeping the tests.

## 1. No fallback on write (0.5 d)

- [ ] 1.1 Failing test (mock API, empty `OrgKeyCache`): `update()` of an org draft throws `VaultError.organizationKeyUnavailable` and the mock API records no request. Today it sends a PUT encrypted with the vault key.
- [ ] 1.2 Failing test: the same for `create()`.
- [ ] 1.3 Implement the D1 helper and use it in `create()` and `update()` (`VaultRepositoryImpl.swift:274-280`, `:325-331`). §VII security comment as in design D1.
- [ ] 1.4 Regression guards: personal item with no org keys still saves with the vault key; org item with its key still saves with the org key (decrypt the request body with each key in the test).

## 2. Atomic key swap (0.5–0.75 d)

- [ ] 2.1 Failing test: `OrgKeyCache.replaceAll(with:)` replaces the map in one call and zeroes the replaced key bytes; a snapshot taken before still holds its own copy.
- [ ] 2.2 Failing test: a sync whose org-key unwrap is slowed down (test double) never exposes an empty snapshot to a concurrent reader. Use a reader task that snapshots in a loop while the sync runs.
- [ ] 2.3 Failing test: a sync that throws after the profile is loaded but before the swap leaves the previous keys in place.
- [ ] 2.4 Failing test: an org missing from a successful sync has no key afterwards.
- [ ] 2.5 Implement D2 in `OrgKeyCache` and `SyncRepositoryImpl.swift:148-160`. Extract the zeroing code shared with `clear()`.

## 3. User-facing error (0.25 d)

- [ ] 3.1 Failing view-model test: `ItemEditViewModel` maps `.organizationKeyUnavailable` to the D3 message, keeps the draft and announces it (§VIII).
- [ ] 3.2 Implement the `VaultError` case and its `errorDescription`.

## 4. Release (0.25–0.5 d)

- [ ] 4.1 Mandatory security review: no write path can pick the vault key for an org item; key bytes zeroed on swap; nothing secret in logs.
- [ ] 4.2 State the overlap in `fix-cipher-edit-data-loss` (KEY-03) and `per-item-key-on-create` (D2) when either is next edited: both refer to this change's rule.
- [ ] 4.3 CHANGELOG "Fixed": organization items can no longer be saved with your personal key while a sync is running or when the organization key is unavailable; such saves now show an error. Add how to recover an item that became unreadable: open it in an official Bitwarden app as the user who saved it and save it again.
- [ ] 4.4 `openspec validate fix-org-key-required-on-write --type change --strict`.
