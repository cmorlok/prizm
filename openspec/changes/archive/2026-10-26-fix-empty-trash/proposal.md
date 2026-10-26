# Proposal

## Why

**Criticality:** P1 (High: the living spec is dangerous)
**Findings:** CF-18 (`06-client-features.md`), W-11 (`04-write-paths.md`)

**The living spec tells implementers to call an endpoint that would wipe the vault.**
`openspec/specs/vault-item-delete/spec.md:53-70` ("User can empty trash") says Empty Trash
"permanently deletes all items in the trash via `DELETE /ciphers/purge`".

- `DELETE /ciphers/purge` does not exist on either server.
- The real route with that path is `POST /ciphers/purge`. It deletes **every item the user owns**,
  trashed or not; on Vaultwarden it also deletes all the user's folders. It is the "Purge vault"
  action of the web vault's account settings.
- Prizm already got close once: during PR #11 (commit `0a06b74`) Empty Trash was implemented
  against the purge endpoint with the master password hash, then removed because re-authentication
  was "not straightforward". Changing the method to `POST` would have deleted users' whole vaults.

**Users have no Empty Trash.** The Trash view offers only one-by-one permanent delete
(`Prizm/Presentation/Vault/Trash/TrashView.swift:31-44`). Trashed items stay until each is deleted
by hand or the server's auto-purge runs (Bitwarden after 30 days; Vaultwarden only if configured).

### Origin of the current behaviour

- **Spec: wrong premise.** It equates "purge" with "empty trash". Commit `0a06b74` removed the
  feature but not the requirement: "The Bitwarden/Vaultwarden purge endpoint requires
  masterPasswordHash re-authentication which is not straightforward to implement."
- **Missing feature: known gap.** Commit `1d1e4b0`: "Empty Trash button is not yet implemented —
  out of scope".

## What Changes

- **Empty Trash is implemented as a bulk permanent delete of the trashed item ids**, with
  `DELETE /api/ciphers` and body `{"ids": [...]}`, in chunks of at most 500 ids. This is what the
  web vault does when the user selects all items in Trash and deletes them.
- **The trash is refreshed first.** Prizm syncs before it shows the confirmation, so the list and
  count are current and an item restored on another device is not deleted.
- **Confirmation with count.** "Permanently delete N items? This can't be undone." Destructive
  button styling, VoiceOver announcement of the result.
- **Partial failures are reported.** After the delete, Prizm syncs again and reports how many items
  are still in Trash.
- **Guard: no purge, ever.** The API client gets no method for `/ciphers/purge`, and a test fails if
  any request path ends in `/purge`.
- **This change supersedes the living requirement** "User can empty trash" in
  `openspec/specs/vault-item-delete/spec.md:53-70`. That file must be updated at archive time
  (task 6.3).

## Capabilities

### New Capabilities
- `empty-trash`: Empty Trash permanently deletes exactly the items in Trash, never anything else.

### Modified Capabilities
_None in this change_ (MODIFIED deltas against `vault-item-delete` are avoided because that spec
does not pass strict validation). The requirement in this change replaces
`vault-item-delete/spec.md` "User can empty trash" in full, including all five scenarios that name
`DELETE /ciphers/purge`.

## Non-Goals

- "Purge vault" (account settings). Prizm will not offer it.
- Multi-select delete or restore in Trash (audit W-15). Possible follow-up on the same API call.
- Admin bulk delete (`DELETE /ciphers/admin`) for org items the user can only delete as admin.
- Permission-aware filtering (`permissions.delete`), which belongs to `honour-org-item-permissions`.

## Dependencies

- None hard.
- Soft: `honour-org-item-permissions` (W-06 / W-14). Until it lands, Prizm cannot tell in advance
  which org items in Trash the user may delete; D4 handles the server's answer.
- Soft: `destructive-action-styling` for the button and confirmation style.

## Impact

- **Data:** `PrizmAPIClient.permanentDeleteCiphers(ids:)` (bulk `DELETE /api/ciphers`);
  `VaultRepositoryImpl.emptyTrash()`.
- **Domain:** `EmptyTrashUseCase`; `VaultRepository.emptyTrash() -> EmptyTrashResult`.
- **Presentation:** Trash toolbar button, confirmation, result message; `VaultBrowserViewModel`.
- **No new dependencies.**
- **Security review: yes.** Irreversible deletion of vault data (§III, vault-touching code).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm bulk delete on both servers | 0.25 d |
| 2 | API call, chunking, purge guard | 0.5 d |
| 3 | Repository and use case, sync before and after | 0.5 d |
| 4 | Trash toolbar button, confirmation, accessibility | 0.5 d |
| 5 | Partial failure reporting | 0.25 d |
| 6 | Security review, CHANGELOG, spec correction | 0.25–0.5 d |
| **Total** | | **2.25–2.5 d** |
