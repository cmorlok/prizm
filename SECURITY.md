# Security

Prizm is a password manager. This document explains exactly how it protects your
data — what is encrypted, where keys live, what threats it defends against, and what
it does not. The goal is to let any developer or technically literate user audit the
implementation and decide whether to trust it. No black boxes.

---

## Reporting a Vulnerability

Please do **not** open a public GitHub issue for security vulnerabilities.

Report privately via GitHub's [Security Advisories](https://github.com/b0x42/prizm/security/advisories/new)
or email the maintainer directly (address in the GitHub profile). Include a description
of the issue, steps to reproduce, and any relevant log output or proof of concept.

---

## Encryption

### Data at rest

No vault data is ever written to disk in plaintext. The only sensitive material
persisted on disk is the **encrypted user key**, stored in the macOS Keychain under
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — accessible only when the Mac is
unlocked and only on this specific device, excluded from iCloud Keychain and backups.

| Data | How it is protected |
|------|---------------------|
| Vault items (passwords, card numbers, identities, notes, SSH keys, custom fields) | AES-256-CBC + HMAC-SHA256; decrypted in memory after unlock only, never written to disk |
| File attachments | Two-layer AES-256-CBC + HMAC-SHA256; plaintext exists in memory only during upload/download; see "File Attachments" section |
| Master password | Never stored anywhere; used transiently during KDF and then discarded |
| Encrypted user key (`encUserKey`) | AES-256-CBC encrypted by the stretched master key; stored in Keychain |
| Access and refresh tokens | Stored in Keychain under `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| KDF parameters | Stored in Keychain; required for offline unlock |

### Data in transit

All API communication uses HTTPS/TLS. Vault data is **encrypted before it leaves the
device** — when creating or editing an item, the client encrypts the plaintext fields
using the vault symmetric keys and sends only ciphertext to the server. The server
never receives plaintext vault content or the master key at any point.

Authentication sends a one-way derived hash (`serverHash`) rather than the master
password itself.

### Algorithms

| Algorithm | Purpose | Implementation |
|-----------|---------|----------------|
| AES-256-CBC + PKCS7 | Vault item encryption / decryption | CommonCrypto (`kCCAlgorithmAES128`, 256-bit key) |
| AES-256-CBC + PKCS7 (Bitwarden binary blob) | File attachment blob encryption | CommonCrypto; blob format: IV(16) ‖ ciphertext ‖ HMAC(32) per Bitwarden Security Whitepaper §4 |
| HMAC-SHA256 | MAC verification (Encrypt-then-MAC) for both vault items and attachments | CryptoKit `HMAC<SHA256>` |
| PBKDF2-SHA256 | Master key derivation (PBKDF2 accounts) | CommonCrypto `CCKeyDerivationPBKDF` |
| Argon2id | Master key derivation (Argon2id accounts) | `Argon2Swift` — thin wrapper around the reference C implementation |
| HKDF-SHA256 | Key stretching | CryptoKit `HKDF<SHA256>` (RFC 5869) |
| RSA-OAEP-SHA1 | Organisation key unwrapping | `Security.framework` `SecKeyCreateDecryptedData` with `kSecKeyAlgorithmRSAEncryptionOAEPSHA1`; SHA-1 is a Bitwarden protocol requirement (Whitepaper §4), not a free choice |

No hand-rolled cryptographic algorithms are used. All implementations are Apple system
frameworks or the vendored `Argon2Swift` package (Argon2id is not provided by Apple
frameworks).

---

## Key Management

### Where keys live

| Key material | Storage | Lifetime |
|---|---|---|
| Master key (32 bytes) | In-memory only | Derived on login/unlock; zeroed right after use (login, unlock, also on error); the Argon2id buffers are zeroed before they are freed |
| Stretched keys (enc + mac, 64 bytes) | In-memory only | Derived from master key; zeroed right after use. During a two-factor login they are kept until the two-factor step ends (the code is accepted, the login is cancelled or restarted, or the user signs out) and then zeroed; a wrong code keeps them so the user can retry |
| Vault symmetric keys (enc + mac) | In-memory only | Decrypted from `encUserKey`; zeroed on lock |
| RSA private key (PKCS#8, variable) | In-memory only | Decrypted from `profile.privateKey` EncString during sync; zeroed at the end of the sync's organisation step |
| Organisation symmetric keys (64 bytes each) | In-memory only (`OrgKeyCache` actor) | RSA-OAEP-SHA1 unwrapped from `RawOrganization.key` during sync; replaced in one step by every sync (an organisation the user left, or whose key cannot be unwrapped, has no key afterwards); zeroed and cleared on lock and sign-out |
| Encrypted user key (`encUserKey`) | macOS Keychain | Persisted across sessions; deleted on sign-out |
| Biometric vault key (64 bytes) | macOS Keychain (biometric-gated) | Created on user opt-in; deleted on sign-out, disable, or biometric invalidation |
| Access token | macOS Keychain | Persisted across sessions; deleted on sign-out |
| Refresh token | macOS Keychain | Persisted across sessions; deleted on sign-out |
| KDF parameters | macOS Keychain | Persisted across sessions; deleted on sign-out |
| Device identifier (UUID) | macOS Keychain | Stable across sessions; kept on sign-out, as in the official clients, so the server keeps recognising the device |

### Key lifecycle

1. **Login** — master password + email → KDF (PBKDF2 or Argon2id) → master key →
   HKDF → stretched keys → decrypt `encUserKey` → vault symmetric keys. All in memory.
2. **Sync (organisation keys)** — `SyncRepositoryImpl.sync()` performs additional key
   setup when the account belongs to one or more organisations:
   a. Decrypt `profile.privateKey` EncString with vault symmetric keys → raw RSA private key (PKCS#8); held in actor state.
   b. For each `RawOrganization` in the sync response, strip the PKCS#8 wrapper, import the RSA private key via `SecKeyCreateWithData`, and decrypt `RawOrganization.key` (a Type-4 EncString) with `SecKeyCreateDecryptedData` / `kSecKeyAlgorithmRSAEncryptionOAEPSHA1` → 64-byte org symmetric key.
   c. Store each org key in `OrgKeyCache` keyed by `organizationId`.
   d. Org cipher fields are then decrypted using the org symmetric key rather than the personal vault key, with collection names decrypted via the same org key.
3. **Lock** — `AuthRepositoryImpl.lockVault()` zeroes the vault keys and clears the
   per-item key cache and `OrgKeyCache`: each `CryptoKeys` entry's underlying `Data` bytes
   are overwritten with zeros before the dictionary entry is removed. Keychain entries are
   retained so the vault can be unlocked offline without re-authenticating to the server.
4. **Sign out** — the same teardown as lock (sign-out calls `lockVault()`, also when
   "Sign in with a different account" is chosen on the unlock screen), and all Keychain
   entries for the account except the device identifier are deleted. The app returns to a
   blank login screen.

### Limits of zeroing in Swift

Prizm zeroes the key buffers it owns. Swift's `Data` is copy-on-write: a buffer is zeroed in
place only while Prizm holds its sole reference, so the code zeroes after every other holder is
gone, and each key's two halves have their own buffers (tests check the in-place zeroing for the
master, stretched and two-factor keys). Copies made inside system frameworks (Foundation,
CommonCrypto, Security, for example the buffer an RSA decryption returns) or held by work still in
flight cannot be reached and stay until the memory is reused. `String` values, such as the server password hash kept during a
two-factor login, cannot be zeroed at all. Keys are not held in locked (`mlock`) memory.

### Debug logging

`--debug-mode` writes extra lines to the unified log. They never contain key material, tokens,
the password hash, the email, two-factor codes or the device identifier; token request
parameters are logged from an allow-list. Text that comes from the server is logged as private in
these debug lines.

### Error logging

Errors are written to the public log only as an HTTP status, a URL error code, or the error's type
and case (`ErrorLog.describe`). Error messages, server response bodies and user data are never
logged publicly. Users see the server's own message for a failed request, never the raw response.

### Biometric vault key (Touch ID / Face ID)

When the user enables biometric unlock, the vault symmetric keys (`CryptoKeys`, 64
bytes: 32-byte encryption key + 32-byte MAC key) are stored in a separate macOS
Keychain item protected by `SecAccessControl` with `.biometryCurrentSet`.

| Property | Value |
|---|---|
| What is stored | `CryptoKeys` — 64 bytes (encryptionKey ‖ macKey) |
| Access control | `.biometryCurrentSet` — requires successful biometric evaluation; invalidated if fingerprints are added or removed |
| Keychain class | `kSecClassGenericPassword` with `kSecUseDataProtectionKeychain: true` |
| Synchronizable | `kSecAttrSynchronizable` is NOT set — device-only, never backed up or synced to iCloud |
| Access group | Inferred from `keychain-access-groups` entitlement — not accessible to other apps |
| Created when | User explicitly opts in (enrollment prompt or Settings toggle), vault must be unlocked |
| Deleted when | Sign-out, user disables toggle, or biometric enrollment changes (`.biometryCurrentSet` invalidation) |

How this compares with the official apps: the Bitwarden iOS app uses the same model (a keychain
item with a biometric access control). The Bitwarden desktop app on macOS stores the user key in
the login keychain without a biometric access control and asks for Touch ID in the app
(`apps/desktop/src/key-management/biometrics/os-biometrics-mac.service.ts`). In Prizm the access
control is evaluated with the Secure Enclave; the key itself is not stored in the Secure Enclave.

The master password is **never** stored in the biometric Keychain item. Only the
already-derived vault symmetric keys are cached. On biometric unlock, the keys are
read directly and passed to `PrizmCryptoService.unlockWith(keys:)`, skipping the KDF
entirely.

---

## File Attachments

Attachments use the Bitwarden two-layer client-side encryption scheme (Security Whitepaper §4).
No plaintext file content is ever sent to the server.

### Encryption scheme

Three encrypted artifacts are produced per attachment:

| Artifact | What it is | How it is encrypted |
|---|---|---|
| Encrypted file blob | The full file contents | AES-256-CBC + HMAC-SHA256 using the per-attachment key; binary layout: IV(16) ‖ ciphertext ‖ HMAC(32) |
| Encrypted attachment key | 64-byte random per-attachment key | EncString type-2 (AES-256-CBC + HMAC-SHA256) using the cipher key |
| Encrypted file name | The original file name | EncString type-2 (AES-256-CBC + HMAC-SHA256) using the cipher key |

The **cipher key** is either the vault symmetric key or a per-item key (if the cipher has
one). The **attachment key** is a freshly generated 64-byte random value for each upload.

### Key locations

| Key material | Storage | Lifetime |
|---|---|---|
| Per-attachment key (64 bytes) | In-memory only | Exists from the start of `upload()` until it returns; zeroed in `defer` |
| Cipher key (64 bytes) | In-memory only | Passed in from the calling use case; never persisted by the repository |
| Encrypted attachment key (EncString) | Bitwarden/Vaultwarden server | Stored as part of the cipher metadata; decrypted on demand during download |

### Temp file lifecycle (Open action)

When a user opens an attachment, the decrypted plaintext is written to a system temp
directory file and opened with the default application. The temp file is:

1. Overwritten with zeros then deleted after **30 seconds** (deadline-based cleanup).
2. Cleaned up on every **foreground transition** (`NSApplication.didBecomeActiveNotification`).

The 30-second window is a trade-off: long enough for the application to load the file,
short enough to limit plaintext exposure if the user switches away without closing the file.

### Upload-incomplete state

If a network failure occurs after the server creates attachment metadata but before the
encrypted blob is fully uploaded, the attachment is marked `isUploadIncomplete = true`.
The server retains the empty metadata record. The client shows a "Retry" action which:
1. Deletes the orphaned metadata record via `DELETE /api/ciphers/{id}/attachment/{attachmentId}`.
2. Performs a fresh upload as a new attachment.

### Threat model additions

- **Server sees only ciphertext** — attachment keys and file contents are encrypted
  before the first API call; the server never receives plaintext.
- **Per-attachment key isolation** — each file is encrypted with an independent 64-byte
  key; compromising one attachment key does not expose other attachments.
- **Temp file exposure window** — the plaintext is on disk for at most 30 seconds after
  opening. A disk image captured during this window could recover the file content.
  Full-disk encryption (FileVault) is strongly recommended.
- **Memory during upload/download** — raw file bytes are held in memory only for the
  duration of the operation, then zeroed. A memory dump during an active upload/download
  could reveal the plaintext.

---

## Verification Codes (TOTP)

Prizm can show the current one-time code for any Login that has a TOTP seed, in the
item's detail pane and in a "Codes" list.

- **Where codes come from** — The seed is already in your synced vault and is decrypted with
  the rest of the item. A code is derived from it on demand using RFC 6238 (TOTP) on top of
  RFC 4226 (HOTP), with HMAC-SHA-1, HMAC-SHA-256, or HMAC-SHA-512 as the seed specifies.
  The HMAC comes from Apple CryptoKit, behind `PrizmCryptoService`; nothing is hand-rolled.
  It is verified against the RFC 6238 Appendix B and RFC 4226 Appendix D test vectors.
- **SHA-1** — SHA-1 is the RFC 6238 default and what almost every service issues. Its known
  weakness is collision resistance, which HMAC does not depend on, so HMAC-SHA-1 is still a
  sound way to compute a one-time code.
- **Nothing is stored or logged** — Codes and parsed seeds are never written to disk, the
  Keychain, or the logs. Only a count of items whose code is unavailable is logged.
- **Seed never shown or copied** — Only the generated code is displayed. "Copy Code" copies
  the current code (no spaces) and clears it from the clipboard after the chosen delay (default
  30 seconds; see Clipboard sniffing). There is no
  command that copies the raw seed.
- **Always visible, by design** — Codes stay visible without a hide timeout, like other
  authenticator apps. This is a documented, narrow exception in the Constitution (§III,
  proposal [#72](https://github.com/b0x42/prizm/issues/72)). It is bounded: a code is useless
  after at most one validity period (30 s by default); codes are removed when the vault locks,
  when the app is hidden or all its windows are minimized, and when no code view is on
  screen; and nothing is generated or refreshed while the vault is locked.
- **Memory** — The decoded secret is copied into a private buffer that is overwritten after
  each code is computed. This is best effort: Swift `Data` is copy-on-write and CryptoKit
  makes its own copy of the key, so some copies cannot be zeroed, and the seed `String`
  already lives in the unlocked vault.
- **Not supported** — Steam-style seeds and HOTP links show "Code unavailable" rather than a
  wrong code.

---

## Threat Model

### What this app defends against

- **Server compromise** — The server never receives the master password, master key,
  or plaintext vault data. A fully compromised server exposes only ciphertext; an
  attacker must still brute-force the KDF to decrypt it.
- **Disk / at-rest compromise** — Vault data is never on disk in plaintext. The
  encrypted user key in the Keychain cannot be decrypted without the master password.
- **Memory dump after lock** — All key material is zeroed on lock. A memory dump
  taken after the vault locks reveals no usable keys.
- **Clipboard sniffing** — Every Copy button and menu command (detail pane, Item menu, Codes
  list, password generator) goes through one clipboard service. It marks the item as concealed
  (`org.nspasteboard.ConcealedType`), so clipboard managers that honour the nspasteboard.org
  convention keep it out of their history, and clears it after the delay chosen in Settings →
  Security (Never, 10 s, 20 s, 30 s, 1 min, 2 min or 5 min; default 30 s). Locking, signing out
  and quitting Prizm normally clear it as well, even with "Never" (a crash or force quit does not). Prizm only clears what it put there: if
  another app copied something since, the clipboard is left alone. Not prevented: other apps can
  read the clipboard during the delay, Universal Clipboard (Handoff) can carry it to the user's
  other devices, and text the user selects in a field and copies with ⌘C is copied by macOS
  without the marker and is not cleared.
- **Network eavesdropping** — All server communication uses HTTPS/TLS. Vault payloads
  are encrypted before transmission regardless.

### What this app does NOT protect against

- **Compromised macOS installation** — The app relies on macOS sandboxing, Keychain
  integrity, and process isolation. A rootkit or kernel exploit invalidates these
  guarantees.
- **Shoulder-surfing or screen capture of verification codes** — Codes are shown on screen
  while the vault is unlocked. Anyone who can see or record the screen can read them, and a
  wrong device clock produces codes the service will reject.
- **Debugger or memory inspector while unlocked** — While the vault is unlocked, key
  material exists in process memory. An attacker with `task_for_pid` or debugger
  access can read it.
- **Keylogger** — The master password is entered via the keyboard. A keylogger can
  capture it before it reaches the app.
- **Physical access while the Mac is unlocked** — Keychain items with
  `WhenUnlockedThisDeviceOnly` are accessible to the app whenever the Mac is in an
  unlocked state.
- **TLS interception (MitM on server identity)** — Certificate pinning is not
  implemented. TLS validation relies on the system trust store.
- **Organisation vault access control** — Org keys are RSA-unwrapped client-side; the
  server cannot selectively withhold an org key without breaking sync entirely.
  Role enforcement (owner / admin / manager / user) is applied in the UI layer only
  (e.g., collection management is hidden for non-admin roles). A determined attacker
  with full memory access while the vault is unlocked could bypass these UI gates and
  read or modify org ciphers they have a key for.

---

## Runtime Protections

The app is built with App Sandbox and Hardened Runtime enabled:

- Outbound network connections: allowed (Bitwarden/Vaultwarden API, icon service)
- Inbound network connections: denied
- File system access: read-only, user-selected files only
- No access to camera, microphone, contacts, calendars, location, Bluetooth, USB, or printing

---

## Standards and References

- [Bitwarden Security Whitepaper](https://bitwarden.com/help/bitwarden-security-white-paper/) — vault architecture, key derivation, encryption flow, attachment encryption (§4)
- [RFC 5869](https://tools.ietf.org/html/rfc5869) — HKDF
- [RFC 8018](https://tools.ietf.org/html/rfc8018) / [NIST SP 800-132](https://csrc.nist.gov/publications/detail/sp/800-132/final) — PBKDF2
- [RFC 9106](https://tools.ietf.org/html/rfc9106) — Argon2id
- [NIST SP 800-107](https://csrc.nist.gov/publications/detail/sp/800-107/rev-1/final) — HMAC
