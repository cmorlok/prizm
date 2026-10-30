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
| KDF parameters and master password salt | Stored in Keychain; required for offline unlock |

### Data in transit

All API communication uses HTTPS/TLS. Vault data is **encrypted before it leaves the
device** — when creating or editing an item, the client encrypts the plaintext fields
using the vault symmetric keys and sends only ciphertext to the server. The server
never receives plaintext vault content or the master key at any point.

Authentication sends a one-way derived hash (`serverHash`) rather than the master
password itself.

### Website icons

Logins show the icon of their website. The request goes to the signed-in account's icon service,
`{server}/icons/{host}/icon.png` (or the icons URL override), and never to a host Prizm picks
itself; before sign-in, while locked and after sign-out nothing is requested.

- **What it reveals:** the website host of each login shown, to your server (Vaultwarden
  fetches the icon from the website itself unless `DISABLE_ICON_DOWNLOAD` is set). Only website
  addresses (`http`, `https` or no scheme) whose host has a dot are sent; `.onion`, `.i2p`, app URIs and dot-less intranet names are
  not. Paths, user names and passwords in the URI are never part of the request.
- **No credentials:** icon requests carry no `Authorization`, no `Bitwarden-Client-*` headers and
  no cookies.
- **Redirects:** a redirect within the server's own origin (scheme, host, port) is followed. A
  redirect to another origin, which a server sends when it is set to use an outside icon service
  (Vaultwarden `ICON_SERVICE`), is refused unless "Allow icons from other services" is on; that
  service then sees the website host and your IP address.
- **No disk cache:** an ephemeral session without URL cache or cookie storage; icons are kept in
  memory only and dropped on lock and sign-out. The shared URL cache that older versions filled
  is emptied at every launch.
- **Settings → Privacy:** "Show website icons" (on by default, as in the official apps) stops all
  icon requests when off; "Allow icons from other services" (off by default) is described above.

### Algorithms

| Algorithm | Purpose | Implementation |
|-----------|---------|----------------|
| AES-256-CBC + PKCS7 | Vault item encryption / decryption | CommonCrypto (`kCCAlgorithmAES128`, 256-bit key) |
| AES-256-CBC + PKCS7 (Bitwarden binary blob) | File attachment blob encryption | CommonCrypto; blob format: the official EncArrayBuffer type 2, `0x02` ‖ IV(16) ‖ HMAC(32) ‖ ciphertext (Bitwarden SDK `enc_string/symmetric.rs`). Files written by Prizm up to 1.5.0 (IV ‖ ciphertext ‖ HMAC) are still read and can be converted |
| HMAC-SHA256 | MAC verification (Encrypt-then-MAC) for both vault items and attachments | CryptoKit `HMAC<SHA256>` |
| PBKDF2-SHA256 | Master key derivation (PBKDF2 accounts); salt = master password salt, 32-byte output | CommonCrypto `CCKeyDerivationPBKDF` |
| Argon2id | Master key derivation (Argon2id accounts); version 0x13, Argon2 salt = SHA-256 of the master password salt, memory = server value in MiB × 1024 KiB, 32-byte output, as the Bitwarden SDK | `Argon2Swift` — thin wrapper around the reference C implementation |
| HKDF-SHA256 | Key stretching | HKDF-Expand without Extract (RFC 5869 §2.3), one HMAC-SHA256 block from CryptoKit `HMAC<SHA256>`; tested equal to CryptoKit `HKDF<SHA256>.expand` and the Bitwarden SDK vector |
| RSA-OAEP-SHA1 | Organisation key unwrapping | `Security.framework` `SecKeyCreateDecryptedData` with `kSecKeyAlgorithmRSAEncryptionOAEPSHA1`; SHA-1 is a Bitwarden protocol requirement (Whitepaper §4), not a free choice |

The **master password salt** is the salt the server sends at prelogin, else the account's
email; it is trimmed and lowercased before use, as the Bitwarden SDK does. Prizm stores the salt
and KDF settings that decrypted the user key and uses them for unlock.

**KDF minimums.** Before deriving a key, at login and at unlock, Prizm checks the KDF settings
against the minimums of the Bitwarden SDK: PBKDF2 at least 5 000 iterations; Argon2id at least
2 iterations, 16 MiB memory and parallelism 1. Below them it refuses to sign in or unlock ("too weak"), as the
official clients do, so a malicious server can't obtain a cheap password hash by sending weak
settings. Prizm is stricter than the SDK in one way: Argon2id memory above 1 024 MiB and parallelism
above 16 are refused as unusable, because no server lets an account store them and they would let
a server exhaust the Mac's memory. Unknown KDF types, missing, zero or negative values are refused
too. Nothing is sent to the server when the settings are refused. Iteration counts are not capped
below what the KDF APIs accept, so a hostile server can keep the CPU busy with a huge count (accepted:
it costs time, not secrets, and the user can quit Prizm).

**Accepted EncString types.** Encrypted vault values (item fields, item keys, folder and
collection names, attachment keys and names, the user key, the private key) are decrypted only
from EncString type 2 (AES-256-CBC + HMAC-SHA256), and the MAC is checked before any decryption.
Type 0 (AES-CBC without a MAC) is never decrypted, not even with the right key: a server, or anyone
who can change stored data, could otherwise strip the MAC from a field, flip ciphertext bits and
have the altered value shown, or use decryption errors as a padding oracle. The official SDK and
apps refuse type 0 too, so such items are unreadable there as well; Prizm leaves them out of the
vault and counts them as failed. The RSA types 3–6 and COSE type 7 are refused where a symmetric
value is expected. IV (16 bytes), MAC (32 bytes) and ciphertext lengths are checked before any
AES call. Organization keys are unwrapped only from type 4 (RSA-OAEP-SHA1), as current clients
write them; types 3, 5 and 6 are refused with their type number in the log. The PKCS#8 private key
is parsed with every length checked, so a malformed key fails instead of crashing.

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
| KDF parameters | macOS Keychain | The settings that decrypted the user key; persisted across sessions; deleted on sign-out |
| Master password salt (`masterPasswordSalt`) | macOS Keychain | The salt that decrypted the user key; persisted across sessions; deleted on sign-out. Installs from before it was stored use the email |
| Device identifier (UUID) | macOS Keychain | Stable across sessions; kept on sign-out, as in the official clients, so the server keeps recognising the device |

### Key lifecycle

1. **Login** — master password + salt (server salt or email) → KDF check → KDF (PBKDF2 or Argon2id) → master key →
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
master, stretched and two-factor keys, the organization and per-item keys on lock and sign-out,
and the user-key buffer used while unlocking). A sync replaces the per-item keys of the previous
sync without zeroing them. Copies made inside system frameworks (Foundation,
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
| Encrypted file blob | The full file contents | AES-256-CBC + HMAC-SHA256 using the per-attachment key; binary layout: `0x02` ‖ IV(16) ‖ HMAC(32) ‖ ciphertext; the HMAC covers IV ‖ ciphertext and is checked before decryption |
| Encrypted attachment key | 64-byte random per-attachment key | EncString type-2 (AES-256-CBC + HMAC-SHA256) using the cipher key |
| Encrypted file name | The original file name | EncString type-2 (AES-256-CBC + HMAC-SHA256) using the cipher key |

The **cipher key** is the item's own key if it has one, otherwise the organization key for an
organization item, otherwise the vault symmetric key, as in the official clients. Sync and create
record which of the three applies to every item; an item without a record, or an organization item
whose organization key is missing, fails with an error instead of falling back to the vault key.
Attachments that Prizm versions before this rule wrapped with the vault key on organization items
stay listed, open with the vault key, and are marked "Only you can open this file". The
**attachment key** is a freshly generated 64-byte random value for each upload.

### Key locations

| Key material | Storage | Lifetime |
|---|---|---|
| Per-attachment key (64 bytes) | In-memory only | Exists from the start of `upload()` until it returns; zeroed in `defer` |
| Cipher key (64 bytes) | In-memory only | Passed in from the calling use case; never persisted by the repository |
| Encrypted attachment key (EncString) | Bitwarden/Vaultwarden server | Stored as part of the cipher metadata; decrypted on demand during download |

### Temp file lifecycle (Open action)

When a user opens an attachment, the decrypted plaintext is written to a file in one folder,
`<temp>/PrizmAttachments` (owner-only, mode `0700`), and opened with the default application.
Files in that folder are:

1. Overwritten with zeros then deleted after **30 seconds** (deadline-based cleanup).
2. Cleaned up on every **foreground transition** (`NSApplication.didBecomeActiveNotification`).
3. All removed on **lock**, **sign-out** and **quit**, and at **launch** (files a crash left behind).

The 30-second window is a trade-off: long enough for the application to load the file,
short enough to limit plaintext exposure if the user switches away without closing the file.
Deletion is the control that matters; the zero overwrite is best effort, because APFS
copy-on-write and SSD wear levelling can keep the old blocks (FileVault protects those).
Prizm does not close the file in the application that opened it: such an app keeps its own
copy in memory after the file on disk is gone.

### Failed uploads

If the encrypted file upload fails after the server created the attachment record (network
error, cancellation, server rejection), Prizm deletes that record right away
(`DELETE /api/ciphers/{id}/attachment/{attachmentId}`), so no broken entry stays in the vault.
Only when that delete fails too does Prizm say that a broken entry may remain; the user can
delete it from the item. A download that finds no file on the server marks the attachment as
missing and offers only Delete.

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

- Outbound network connections: allowed (Bitwarden/Vaultwarden API, the server's icon service)
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
