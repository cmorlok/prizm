# Changelog

## Unreleased

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
