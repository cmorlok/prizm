# Proposal

## Why

Bitwarden keeps a per-item **password history**: when a login's password (or a hidden custom field)
changes, official clients record the old value with a timestamp in `cipher.passwordHistory`. That
history syncs to every client. Users rely on it to recover from a password change that did not take
effect on the website, or to find out which password an old backup or device still uses.

Prizm ignores it completely:
- **Not displayed.** History created by other clients is invisible in Prizm.
- **Not recorded.** Changing a password in Prizm does not add the old one, so official clients
  never see Prizm's changes in the history.
- **Not modelled.** `fix-cipher-edit-data-loss` makes Prizm *preserve* the history on edit, but only
  as opaque encrypted data. Its design records the missing append as a deferred gap (D3) and points
  to this change.

## What Changes

- **Record history on save.** When a login's password changes, the old password is added to the
  item's history with the current date. The same applies when a hidden custom field's value
  changes or the field is removed, on any item type, using official clients'
  `"<field name>: <old value>"` format. History is capped at the 5 most recent entries, as in
  official clients (confirmed in the SDK source, design Context).
- **Show history on demand.** The detail view footer gets a "Password history: N" button, shown
  only when N > 0. It opens a sheet listing the entries newest first, each with its date and the
  value masked. The user can reveal (eye toggle or Option peek) and copy each value (clipboard
  cleared after the user's clipboard clear delay, as for passwords).
- **Decrypt only while the sheet is open.** Entries are decrypted when the sheet opens and released
  (the view model's array emptied) when it closes or the vault locks.
- **"Password updated" date.** The footer shows "Password updated: dd.MM.yyyy" from
  `passwordRevisionDate` when present, above "Updated" and "Created".

## Capabilities

### New Capabilities
- `password-history`: recording, storing, displaying and copying past passwords of an item.

### Modified Capabilities
- `detail-card-view`: the metadata footer adds "Password updated" and the "Password history" button.

## Non-Goals

- Deleting individual history entries or clearing the history. Official clients do not offer this
  for item history either.
- Password *generator* history (Bitwarden's separate, local list of generated passwords).
- History for card codes, identity fields or SSH keys. Official clients record the login password
  and hidden custom fields (on any item type) only.
- Restoring an old password with one click. Users can copy it, then edit the item.

## Dependencies

- **Hard:** `fix-cipher-edit-data-loss` (merged), which decodes `passwordHistory` and `passwordRevisionDate`,
  keeps the encrypted originals in the stored server record of each item (`RawCipherStore`, Data
  layer only), and writes with the cipher's effective key over that record.

## Impact

- **Domain:**
  - `LoginContent.passwordRevisionDate: Date?`
  - `VaultItem.passwordHistoryCount: Int` (a count only, no values)
  - `PasswordHistoryEntry` entity (value + date), produced only on demand
  - `GetPasswordHistoryUseCase`
- **Data:**
  - `GetPasswordHistoryUseCaseImpl` decrypts from the stored record in `RawCipherStore` with the
    effective key derived as on save
  - `CipherMapper.toRawCipher` adds new encrypted entries (compared against the stored record, as
    `passwordRevisionDate`) and trims the list to 5
  - `CipherMapper` maps the count and the revision date
- **Presentation:** footer changes in `ItemDetailView`, a new `PasswordHistorySheet` and its view
  model, reusing `MaskedFieldView`, the Option-key peek and the existing copy with the user's
  clipboard clear delay.
- **Security:** old passwords are as sensitive as current ones. They are never in plaintext except
  while the sheet is open, never logged, and masked by default (§III). SECURITY.md gets one row
  under "Data at rest" / "in use".
- **Accessibility:** the button, rows, reveal and copy controls are all labelled. The sheet has a
  header with the `.isHeader` trait (§VIII).

## Estimate

Ideal engineer-days, TDD included, assuming `fix-cipher-edit-data-loss` has landed.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm official-client semantics (cap, hidden fields, entry format) | 0.5 d |
| 2 | Domain model, count and revision date mapping, on-demand decrypt use case | 1–1.5 d |
| 3 | Record history on save (password, hidden fields, cap 5) | 1–1.5 d |
| 4 | History sheet: masked rows, reveal, copy, auto-clear, VoiceOver | 1.5–2 d |
| 5 | Footer: "Password updated" and "Password history: N" | 0.5 d |
| 6 | Security review, interop check with an official client, docs | 0.5 d |
| **Total** | | **5–6.5 d** |
