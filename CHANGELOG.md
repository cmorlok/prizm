# Changelog

## Unreleased

- Fix: a password copied from the password generator was not hidden from clipboard history and
  could stay on the clipboard indefinitely once the edit sheet closed. All copies now go through
  one clipboard service.
- Add a "Clear clipboard" setting in Settings → Security (Never to 5 minutes; default 30 seconds).
  Locking, signing out and quitting Prizm now also clear a secret Prizm copied.
- Security: master and stretched keys are zeroed right after use, including the keys kept during
  a two-factor login, and the Argon2id buffers before they are freed. Locking and signing out now
  clear every key cache through one path, including "Sign in with a different account". Debug mode
  no longer logs the email, the two-factor code or the device identifier, and logs server text as
  private. SECURITY.md now matches this, says that the device identifier is kept on sign-out, and
  compares biometric unlock with the official apps correctly.
- Add Empty Trash to the Trash view. Prizm syncs first, asks "Permanently delete N items?", deletes
  exactly the items in Trash and reports any it could not delete. It never uses the server's
  "purge vault" call, which would delete every item.
- Fix: renaming a collection removed the access of every member and group that is not an owner
  or admin, and its directory-sync link. Prizm now reads the collection's access settings and sends
  them back; if they can't be read, the rename is not sent. On Vaultwarden, this can store a Manage
  permission the server previously only derived, as the web vault does when it saves a collection. New collections are now
  managed by their creator, as in the web vault. Admins: check the access of collections renamed
  with earlier Prizm versions.
- Fix: an organization item could be saved encrypted with your personal key when the
  organization's key was unavailable (for example after it could not be unlocked during sign-in,
  or during a sync), which made it unreadable for everyone else. Such saves now stop with an error
  and keep your input. Signing out now also removes the organization keys from memory. If an organization item became
  unreadable this way, open it in an official Bitwarden app as the user who saved it and save it
  again.
- Fix: the favorite star no longer re-saves the whole item, which could remove data Prizm does not
  show yet, such as passkeys or password history. It no longer needs edit rights for organization
  items, and a failed change shows an error. Bitwarden self-hosted servers on MySQL, PostgreSQL or
  SQLite do not save this kind of change (a server bug); Prizm now says so instead of showing a
  change that disappears at the next sync.
- Fix: moving an organization item to a folder, or deleting its folder, no longer makes it look
  personal until the next sync, and no longer makes the next edit of that item fail.
- Fix signing in on Vaultwarden 1.37.4 and current Bitwarden self-hosted servers: Prizm now asks
  for the account's key settings at the Identity service (`/identity/accounts/prelogin/password`),
  like the official apps. Older servers that lack this route keep working through the older
  Identity route (`/identity/accounts/prelogin`).
- Fix File → New Window (⌥⌘N): it showed "No document could be opened" instead of opening a new
  window.
- **Changed**: "Sign Out…" no longer has a keyboard shortcut. ⌘⇧Q is macOS's own Log Out shortcut.
- Fix the arrow keys in the sidebar and the item list: after clicking a row, ↑ and ↓ now move the
  selection.
- Fix VoiceOver reading stale values: the dots of a masked password after Reveal, the previous
  item's fields after selecting another item, and an old password generator preview.
- Fix a crash when pressing ⌘N while Trash is selected. The "+" button is no longer shown in Trash.
- Fix: locking the vault or signing out now also clears the selected item, the item list and the
  search term from memory. Before, the decrypted item stayed loaded behind the unlock screen and
  Item → Edit stayed enabled.
- Fix signed builds from source: the app target had lost its bundle identifier (since 1.4.0) and
  carried a fixed Team ID that overrode `LocalConfig.xcconfig`. Contributors can now set their own
  bundle identifier with `PRIZM_BUNDLE_IDENTIFIER` (see DEVELOPMENT.md). If you used 1.4.0 to
  1.5.0: those versions saved their settings under a different name, so after updating, turn
  "Unlock with Touch ID" on again and set your password generator options again. The offer to
  enable Touch ID may appear once more, and the "Last synced" time shows again after the next
  sync. Your vault and sign-in are not affected.
- Add verification codes: a login with a TOTP seed now shows its current one-time code and a
  countdown in the item, and a new "Codes" sidebar entry lists every item that has
  one. Supports base32 secrets and `otpauth://totp` links (SHA-1, SHA-256, SHA-512; 6 to 8 digits).
- **Changed**: "Copy Code" (⌃⌘C) now copies the current generated code instead of the raw TOTP
  seed, and the raw seed can no longer be copied.
- Fix a crash when locking the vault (including sleep and screen lock) by using
  the actual index ranges when zeroing sliced organization and vault key buffers.
