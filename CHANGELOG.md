# Changelog

## Unreleased

- Fix: opening or saving an attachment failed on Vaultwarden when the last sync was more than about
  a minute ago. Prizm now asks the server for a fresh download link every time.
- Fix: a failed or cancelled attachment upload no longer leaves a broken attachment entry on the
  item: Prizm deletes the entry again. If that delete fails too, Prizm says so, and you can delete
  the entry yourself.
- Fix: when the server refuses an upload (for example, attachments need a premium account, or the
  storage limit is reached), Prizm shows the server's message.
- Fix: attachment files opened from Prizm are now deleted when the vault locks, when you sign out
  and when Prizm quits; files left behind by a crash are deleted at the next launch.
- Changed: the "Upload incomplete" state and its Retry button are gone. An attachment whose file is
  missing on the server says so and offers Delete.
- Fix: saving an organization item no longer removed it from collections you did not uncheck.
  Picking a collection replaced all of them, and "None" removed the item from every collection.
  A save without a collection change no longer sends the collections at all, so changes another
  member made are kept, and collections you can only view always stay assigned.
- Fix: the collection picker no longer offered collections you can only view (the server refused
  the change), and saving an organization item without a collection change no longer reported
  "the collection change failed" on Vaultwarden.
- Fix: an organization item can no longer be saved without a collection; "None" is gone. Before,
  such an item could disappear for you and for other members.
- Changed: an organization item's collections are now a list of checkboxes, so an item can be in
  several collections. Collections you can only view are shown checked and cannot be removed.
- Fix: accounts that use Argon2id can sign in and unlock. Before, Prizm derived their key
  differently from Bitwarden and the server answered "Invalid email or master password". An email
  typed with spaces before or after it no longer fails to sign in.
- Security: Prizm refuses to sign in or unlock when an account's key-derivation settings are weaker
  than the official Bitwarden apps allow (PBKDF2 with fewer than 5,000 iterations; Argon2id with
  fewer than 2 iterations or less than 16 MiB memory), so a malicious server can't get a password
  hash that is cheap to crack. Raise the settings in the web vault. Settings Prizm can't use at all
  (for example a missing or negative value, or Argon2id memory above 1,024 MiB) are refused too.
- Added: SSH keys can be created in Prizm again. A new SSH key starts with a freshly generated
  Ed25519 key; "Generate new key" makes another, and "Import key…" takes an unencrypted OpenSSH
  Ed25519 private key from the clipboard or a file. Prizm checks that the private and public key
  belong together and saves the fingerprint, so the key shows in every Bitwarden app.
  Passphrase-protected keys, RSA and ECDSA keys, and PEM, PKCS#8 and PuTTY files cannot be
  imported yet; Prizm says why and what to do.
- Fix: saving an SSH key that has no fingerprint, such as one created by an earlier Prizm version
  on the Bitwarden server, now adds the fingerprint computed from its public key.
- Fix: an SSH key whose private or public key is missing (for example one that Vaultwarden hides)
  can no longer be edited in Prizm, so a save cannot overwrite the key stored on the server. Prizm
  says to repair it in a Bitwarden app.
- Changed: the private key, public key and fingerprint of an SSH key are read-only in the edit
  sheet, as in the other Bitwarden apps. Name, notes and custom fields stay editable.
- Known issue: SSH keys created by earlier Prizm versions are hidden on Vaultwarden. Recreate them
  in Prizm or another Bitwarden app.
- Removed: creating SSH keys in Prizm, until Prizm can generate or import them. Keys created in
  Prizm had no fingerprint, so Vaultwarden hid them. Create SSH keys in a Bitwarden app for now.
- Known issue: SSH keys created by earlier Prizm versions are hidden on Vaultwarden and have no
  fingerprint on the Bitwarden server. Recreate them in a Bitwarden app.
- Fix: editing an item no longer deletes custom fields without a name or websites without an
  address, and no longer changes field types, linked fields or website match rules that Prizm does
  not know. Prizm shows them as "Unnamed field", "Unsupported field type" (read-only, hidden like a
  password), "Unknown field" and "Unknown match rule"; a website without an address appears only in
  the edit sheet, as an empty row. Items that earlier versions already changed can't be repaired.
- Fix: the edit and New Item sheets were so short that only about three fields showed,
  organization items worst. The sheet now asks for 800 pt; in a smaller window it fits the window
  and the fields scroll.
- Fix: the Settings button (gear) had moved into the toolbar's overflow menu, so it was hidden, and
  VoiceOver users did not find it in the toolbar. It is back next to the sidebar toggle; the
  sidebar is now at least 220 pt wide.
- Fix: VoiceOver could read the previous item's value, a value from before an edit, or the dots of
  a revealed password in the item details and the password generator. It now always reads the text
  on screen.
- Fix: editing an item in Prizm no longer deletes data that other Bitwarden apps added to it:
  passkeys, password history, the archived state and an SSH key's fingerprint now stay on the item.
- Fix: items that other Bitwarden apps encrypted with their own key no longer disappear from
  Prizm. They can be read and edited, and keep their key.
- Fix: saving an edit that is based on an outdated copy is rejected instead of overwriting a newer
  change made in another app. Prizm tells you the item changed, offers to reload it, and you make
  your change again.
- Fix: creating and editing items works on Vaultwarden 1.37.4, which answered "Server error 422."
  Items that earlier Prizm versions already damaged cannot be repaired. Password history is kept
  on edit, but Prizm does not yet add the old password to it.
- Fix: clicking the favorite star twice quickly left the item starred. Repeated clicks are now
  applied in order, and the item ends in the state of the last click.
- Fix: locking Prizm (⌘L, sleep, screensaver) while it unlocked, signed in or synced right after
  could show the vault again when that ended, or was ignored. The lock now stays in effect.
- Fix: when the server rejects a request, Prizm shows the server's message (for example "Folder
  name too long") instead of "Server error 400:" followed by the raw response. The macOS log no
  longer records error messages or server responses, only status codes and error types.
- Changed: card brand and expiry month are chosen from lists and saved in the same format as other
  Bitwarden apps ("Amex", month "3", year "2027"); the brand is detected from the card number, and
  the detail view shows the expiry as "03 / 2027". Values that match no list entry are kept.
- Fix: new logins no longer get an empty website entry.
- Fix: organization items that you filed in your folders in other Bitwarden apps now show in those
  folders (folder counts include them), and you can file organization items into folders in Prizm,
  with the edit sheet or drag and drop, also items in read-only collections. Folders stay personal;
  other members do not see your filing.
- **Changed**: Prizm now identifies itself to the server as a macOS desktop client on every request
  (`Device-Type`, `Bitwarden-Client-Name`), so Vaultwarden's event logs no longer show it as an
  unknown browser. Its user agent shows the Prizm version instead of a Bitwarden version.
- Fix: "Open in browser" on a website now opens only web and other safe link types (the official
  Bitwarden apps' list), never `file:` or custom app links from a shared item, and works for
  addresses saved without `http://`. There is no button when no app on the Mac can open the link.
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
