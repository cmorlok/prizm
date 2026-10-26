# Changelog

## Unreleased

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
