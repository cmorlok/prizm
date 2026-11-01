# Design

## Context

**Wire format.** Source: Bitwarden SDK `bitwarden_vault::cipher`.
`cipher.passwordHistory` is an array of `{ password: EncString, lastUsedDate: ISO-8601 }`, newest
first. `password` is encrypted with the cipher's effective key. `login.passwordRevisionDate` is a
plain ISO-8601 date.

**Official-client behavior on save** (task 1.1, confirmed in sdk-internal `c1c9b9a5`,
`crates/bitwarden-vault/src/cipher/cipher.rs:1009-1027` `update_password_history`,
`login.rs:387-413` `detect_password_change`, `field.rs:126-158` `detect_hidden_field_changes`,
`password_history.rs:13,93-105`; iOS builds the same in Swift but appends at the end, the SDK, web
and CLI prepend):
- **Password:** an empty or missing old password adds nothing (a first password only sets
  `passwordRevisionDate`); an unchanged password adds nothing; a changed or cleared password adds
  `{ old password, now }`.
- **Hidden custom fields, any item type** (fields live on the cipher, not the login): every
  original field of type hidden with a non-empty name and a non-empty value whose name is missing
  from the edited fields, or whose value there differs, adds `{ "<name>: <old value>", now }`.
  Fields are matched by name (a rename is a removal; with duplicate names the last one wins).
  Text, boolean and linked fields are ignored.
- **Order and cap:** the new entries `[password, fields…]` are reversed, put in front of the
  existing history, and the first 5 are kept (`MAX_PASSWORD_HISTORY_ENTRIES = 5`). The SDK takes
  fields from a `HashMap`, so their mutual order is unspecified; Prizm uses the stored field order.
- **Date:** `lastUsedDate` is the save time; the server stores it with 6 decimal digits whatever the
  client sends (source review 2026-10-25).

**After `fix-cipher-edit-data-loss`:**
- `RawCipher.passwordHistory` (opaque ciphertext, a `JSONValue`) and
  `RawLoginData.passwordRevisionDate` are decoded.
- The encrypted originals stay in the last server record of the item, which the Data-layer
  `RawCipherStore` holds per item id.
- `update()` writes over that stored record and sends them back as received, never decrypted.
- `passwordRevisionDate` is already set on password change.
- History is preserved but never appended (the deferred gap this change closes).

**Detail footer today.** `ItemDetailView.metadataFooter` shows "Updated:" and "Created:" with a
fixed 70 pt label column and `Typography.fieldValue` (spec `detail-card-view`, "Metadata footer").

## Goals / Non-Goals

**Goals**
- History written by Prizm is indistinguishable from history written by official clients.
- Past passwords are never in plaintext in memory unless the user is looking at them.
- Reuse the existing masked-field, peek and copy components. No new interaction patterns.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Decrypt history on demand, not at sync

Other fields are decrypted into `VaultItem` at sync. History is not:
- `CipherMapper` maps only `passwordHistoryCount` (array length) and `passwordRevisionDate`
  (a plain date).
- `GetPasswordHistoryUseCase.execute(itemId:)` delegates to `VaultRepository.passwordHistory(itemId:)`
  (the repository holds the stored records and keys, as for every other use case), which reads the
  stored record from `RawCipherStore` with its generation token, derives the key as `update` does (`effectiveKeys(for:activeKeys:)` over that
  record, then `verifyKey`, no fallback; not `VaultKeyService`, which serves attachments from a cache
  filled separately), checks `isCurrent(token)` before decrypting (else `vaultLocked`), and returns
  `[PasswordHistoryEntry]`.
- Stored shapes (`passwordHistory` is `JSONValue?`): absent or `null` → no entries, count 0; an
  array → one entry per element; an element that is not an object, has no `password`, or does not
  decrypt → an entry "could not be read" (no value, no reveal or copy; logged without values); an
  unparsable or missing `lastUsedDate` → "Unknown date"; a non-array value → count 0, no entries,
  logged at `.error` (names only).
- The sheet's view model holds them and clears them on dismiss and on `.vaultDidLock`.

**Why.** History holds up to 5 extra secrets per item that are almost never looked at. Decrypting
them for every item at every sync puts hundreds of old passwords in memory for no benefit. §III
says to minimise plaintext in memory.

**Rejected alternative:** decrypt at sync like everything else. It is simpler, but it fails §III's
"minimum required lifetime" for no UX gain. Clients keep 5 entries, which decrypt instantly; a
server may send more, and the sheet still shows them all (see Sheet).

### D2. Add new entries without decrypting old ones

The comparison runs in the mapper against the stored server record `base`, the same way
`passwordRevisionDate` is decided today (`CipherMapper.passwordRevisionDate`), so the date and the
history always come from one comparison and one `now` (the mapper's injected clock):
1. Under the effective key (already verified by `verifyKey`), decrypt from `base` the login password
   and the names and values of hidden custom fields (any item type); the compared copies are `Data`
   and zeroed after use, as in `passwordRevisionDate`.
2. `PasswordHistoryPolicy.newEntries(oldPassword:newPassword:oldHidden:newHidden:)` (pure Domain,
   Foundation only) returns the new plaintext entries in SDK order (design Context): fields, then
   the password, after the SDK's `.rev()`.
3. Each new entry's value is encrypted with the effective key; `lastUsedDate` is `now` in the
   mapper's ISO-8601 format, the same instant as `passwordRevisionDate`.
4. The new entries go in front of the existing array of `base` as received (elements copied byte
   for byte, never decrypted); the first 5 are kept. Absent or `null` history starts a new array; a
   non-array value is sent back unchanged with no new entry and logged at `.error`.

Because `base` is the server's record, a retry after `collectionChangeNotSaved` (whose `base` is the
saved record) adds no second entry, and a conflict reload compares against what the server holds.
A folder- or favourite-only edit goes through `/partial` and never reaches this path.

**Where the logic lives.** The rule is the pure Domain function above, unit-testable without crypto;
decrypting the originals, encrypting and merging stay in `CipherMapper`.

### D3. UI

**Footer.** Order: "Password updated" (only if a revision date exists), "Updated", "Created", then
a "Password history: N" button (only if N > 0). The label column widens to fit "Password updated:"
through a new `Spacing.footerLabelWidth` token (with a comment) instead of the fixed 70 pt. The
button uses link styling and `Typography.fieldValue`, like the rows. A sheet width token
`Spacing.historySheetWidth` sizes the sheet. The visibility rules live in
an `ItemFooterModel` (Presentation, plain struct) with unit tests.

**Sheet:**
- Title "Password History" (`.isHeader`).
- Rows sorted by `lastUsedDate`, newest first; equal dates keep array order, and entries without a
  readable date follow in array order (iOS appends at the end, so array order alone is not
  reliable). Each row shows the masked value
  (`MaskedFieldView`, Option peek supported), the date in `dd.MM.yyyy HH:mm` format
  (`Typography.fieldLabel`), and copy on hover, reusing the `FieldRowView` copy affordance. Copy
  clears the clipboard after the user's clipboard clear delay (`ClipboardService`).
- An entry that could not be read shows "Entry could not be read", without reveal or copy.
- A Close button; Esc also closes.
- The rows sit in a lazy stack; more than ten entries scroll inside the sheet at the fixed height
  `Spacing.historyListMaxHeight` (security review 2026-10-31: the server decides the count, so a
  long list must not grow the sheet past the screen or build every row at once). Up to ten keep
  their natural height; a sheet has no height of its own to fit a scroll view to.

VoiceOver:
- row label: "History entry from <date>" (entries also hold hidden-field values); accessibility
  identifiers use the row index, so two entries with the same minute never collide
- value: "hidden" or the revealed value
- copy hint: "Copies value to clipboard" (an entry can be a hidden field value)

**Lock behavior.** On `.vaultDidLock` the sheet dismisses and the view model's array is emptied
in the same main-actor turn as the notification (security review 2026-10-31: a hop through a
`Task` let a finishing load fill the rows after the lock); `String` values cannot be zeroed, so
the guarantee is that no reference outlives the sheet. A load that finishes after lock or dismiss
is dropped (the use case's token check, and the view model ignores a result once dismissed). The
repository's token is bumped only after `lockVault()` returns, so a read can still decrypt in that
short window; `lock-state-machine` (gap 7) closes it for every read.

**Re-prompt.** Items with master-password re-prompt are not gated here; `enforce-master-password-reprompt`
(later, P1) covers reveal and copy across the app, the history sheet included.

## Risks / Trade-offs

- **[Medium] Semantics drift from official clients** (cap, hidden-field format). → Task 1.1 pins
  them from source. Interop test: change a password in Prizm, check that the Bitwarden web vault
  shows the entry, and the other way round.
- **[Low] History for org items.** Encrypted with the org-derived effective key, which is already
  handled by `VaultKeyService`. Covered by tests.
- **[Low] Users expecting deletion.** Out of scope, matching official clients. Mentioned in the
  docs.

## Open Questions

None. Closed 2026-10-30 (Christian): footer button only, no context menu entry or shortcut.

## Review

- Spec challenge (fresh agent, before code): 13 findings, all adopted.
- Code review (fresh agent, 2026-10-31): 0 high/medium, 3 low, all fixed (switching items clears
  the sheet and Close dismisses directly; buffers zeroed before decryption errors can return;
  org-read, missing-org-key, card-removal, boolean/linked and count-after-save tests; green
  20261031T080312Z).
- Security review (fresh agent, 2026-10-31): 0 high/medium, 2 low, both fixed: the lock observer
  dismisses in the notification's own main-actor turn; a long history scrolls in a lazy stack at a
  fixed height. The repository-side window between `lockVault()` and the token bump is gap 7 of
  `lock-state-machine`.
- `/opsx:verify` (2026-10-31): 0 critical, 0 warnings, 4 suggestions (doc comment moved back;
  `ItemFooterModel` stays in the view file because new app files need project entries; link colour
  seen in the hand check; the retry case is covered by the double-save test).
- Rig (Vaultwarden 1.37.4, `bw` 2026.9.1): Prizm's history entries for a password and a hidden field
  read back in the official format, and a password changed with `bw` shows in Prizm's sheet
  (20261031T081759Z).
- UI: the planned XCUITest never saw the sheet in four approved runs and was dropped (Christian,
  2026-10-31); hand checks with VoiceOver cover task 4.3.
