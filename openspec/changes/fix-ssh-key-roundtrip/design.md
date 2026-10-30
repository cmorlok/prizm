# Design

## Context

Sources: `$SRC` checkouts of 2026-10-23 (clients, sdk-internal, ios, server) and Vaultwarden tag
1.37.4.

**Official clients create all three fields together.**
- Web/browser/desktop cipher form: a new SSH item gets a generated Ed25519 key from the SDK
  (`generate_ssh_key("Ed25519")`), or the user imports one from the clipboard. Both fill private
  key, public key and fingerprint at once
  (`clients/libs/vault/src/cipher-form/components/sshkey-section/sshkey-section.component.ts:89-130`).
- All three inputs are `readonly` in the form, on create and on edit
  (`sshkey-section.component.html:10,32,37`).
- SDK: the private key is stored in unencrypted OpenSSH format, the public key in OpenSSH
  `authorized_keys` format, and the fingerprint as `SHA256:<base64>` of the public key
  (`sdk-internal/crates/bitwarden-ssh/src/lib.rs:19-40`, `fingerprint(HashAlg::Sha256)`). Import
  accepts OpenSSH (Ed25519, RSA, ECDSA; encrypted ones with a password) and PKCS#8
  (`sdk-internal/crates/bitwarden-ssh/src/import.rs:20-213`).
- iOS cannot create SSH keys: `CipherType.canCreateCases` has no `.sshKey`
  (`ios/BitwardenShared/Core/Vault/Models/Enum/CipherType.swift:97-99`). Its edit screen shows the
  key with the view-only component (`ios/BitwardenShared/UI/Vault/VaultItem/AddEditItem/AddEditItemView.swift:429`).

**No server derives the fingerprint.**
- Official: `KeyFingerprint = SSHKey.KeyFingerprint`, stored as sent, null accepted
  (`server/src/Api/Vault/Models/Request/CipherRequestModel.cs:416-427`).
- Vaultwarden 1.37.4: when the fingerprint, private key or public key is missing or empty, the
  cipher's type data is replaced by `null` in every response ("Fix invalid SSH Entries",
  `vaultwarden/src/db/models/cipher.rs:298-308`). The stored data is unchanged; only the output is
  nulled.
- Older Vaultwarden versions: 1.32.0 has no SSH key type and rejects type 5 with "Invalid type"
  (`src/api/core/ciphers.rs:472-478`, tag 1.32.0). From 1.33.0 the same "Fix invalid SSH Entries"
  rule applies (`src/db/models/cipher.rs:277`, tag 1.33.0). So SSH key creation in Prizm has never
  produced a visible key on any Vaultwarden version, and nothing here depends on the server
  version.
- Checked on the rig (Vaultwarden 1.37.4, run 2026-10-30, task 1.1): a PUT without
  `keyFingerprint` answers HTTP 200; `/sync` then returns `sshKey: null`; the database row keeps the
  private and public key, with no fingerprint. The key was created with the official `bw` CLI
  2026.9.1, which stands in for the web vault (same SDK).
- Bitwarden self-hosted was not checked (task 1.2): the milestone rig runs Vaultwarden 1.37.4 only.
  The official server's handling above is from its source.

**Prizm today** (after `fix-cipher-edit-data-loss`).
- Write: an edit sends the stored `keyFingerprint` back as received; a create sends none
  (`toRawSSHKey`, `Prizm/Data/Mappers/CipherMapper.swift`).
- Read: an SSH item whose `sshKey` is absent or `null` (what Vaultwarden sends for an incomplete key)
  gets the edit block `unmappable` ("Some of this item's details are missing…"), so it cannot be
  saved (`CipherMapper.editBlock(for:)`). An `sshKey` object with an empty or missing private or
  public key is not blocked.
- Edit form: private key masked and editable, public key editable, fingerprint read-only, with
  comments saying the server derives it (`Prizm/Presentation/Vault/Edit/SSHKeyEditForm.swift`).
  `DraftSSHKeyContent.privateKey` and `publicKey` are `var`, and its comment says the fingerprint is
  "never sent to the API" (`Prizm/Domain/Entities/DraftVaultItem.swift`).
- Create: the New Item menu iterates `ItemType.allCases`, including `.sshKey`
  (`Prizm/Presentation/Vault/VaultBrowserView.swift`); the blank SSH draft has all fields `nil`.
- Test: `CipherMapperReverseTests.test_reverseMapper_sshKeyRoundTrip` asserts that the fingerprint
  is not sent, with the comment "the server returns the authoritative fingerprint post-save".

## Goals / Non-Goals

**Goals**
- Every SSH item Prizm writes has the same private key, public key and fingerprint it had before, or
  Prizm does not write it.
- Prizm never creates an SSH item that Vaultwarden would hide.
- No new cryptographic code in this change.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Edit keeps the fingerprint (adopted)

An edit sends the stored record's `keyFingerprint` back as received, so the fingerprint is no
longer deleted (`fix-cipher-edit-data-loss`, design D2 and D3). This change adds the tests that pin
it: the test at `CipherMapperReverseTests.swift:201-203` is inverted.

### D2. Key fields read-only in the edit sheet (adopted)

`DraftSSHKeyContent.privateKey` and `publicKey` become `let`. `SSHKeyEditForm` shows the three key
values with the detail view's rows (`FieldRowView`): the private key masked with reveal and copy,
the public key and fingerprint as text with copy. VoiceOver reads each row's label and value and
the copy hint ("Copies Public Key to clipboard"), as in the detail view; a text field is no longer
offered, so nothing announces the row as editable. Copy goes through the app's one clipboard
service, so the auto-clear applies (`clipboard-hardening`).

This matches the web form (`readonly`) and the iOS edit screen.

**Rejected alternative:** keep the key fields editable and recompute the fingerprint from the edited
public key. The private key could then still disagree with the public key, and Prizm cannot check
that without parsing private key formats (see D4, option B).

### D3. Incomplete SSH items are not editable (adopted)

`SSHKeyContent.hasKeyMaterial` is true when private key and public key are both non-empty. An SSH
item without key material gets the new edit block `EditBlockReason.incompleteSSHKey`, whose message
is "This SSH key is incomplete and can't be edited in Prizm. Open it in a Bitwarden app to repair
it." The existing edit guard then disables every Edit entry point, reads the message as the Edit
button's VoiceOver hint, and refuses a save in the repository (`fix-cipher-edit-data-loss` D4).
Move to folder, favorite (both use `/partial`, no item data) and delete stay available.

- `CipherMapper.editBlock(for:)` returns `incompleteSSHKey` for a type 5 record whose `sshKey` is
  absent or `null`, or whose private or public key is absent or an empty string. This replaces
  `unmappable` for SSH items: the specific message tells the user what is wrong.
- `CipherMapper.map` also sets it when the decrypted private or public key is empty, which the raw
  check cannot see.

Why: on Vaultwarden, an incomplete item arrives as `sshKey: null`, while the server still holds the
real key data. Any full PUT from Prizm would overwrite it with `null`.

A missing fingerprint alone does not block editing. That case occurs on the official server for
SSH items created by earlier Prizm versions; there the server returns the keys, and an edit keeps
the fingerprint as it is (`nil`), so nothing gets worse.

**Rejected alternative:** allow editing name and notes and re-send the SSH block unchanged. Prizm
never received the SSH block (Vaultwarden nulls it), so there is nothing to re-send.

### D4. Creating SSH keys: three options

| | Option | What the user does | Risk | Effort |
|---|---|---|---|---|
| A | Require all three fields | Paste private key, public key and fingerprint by hand | Prizm cannot check that they match. A typo in the fingerprint is stored as truth; a mismatched pair breaks SSH agents that rely on it. Poor UX. | 0.5 d |
| B | Import (and later generate) with a computed fingerprint | Paste or pick an OpenSSH private key; Prizm derives the public key and fingerprint | See below | 3–5 d |
| C | Remove SSH key creation until B exists | Create SSH keys in an official Bitwarden app | No new risk; feature regression for the few users who created keys in Prizm (which were broken anyway) | 0.25 d |

**Assessment of B (crypto-adjacent).**
- The fingerprint is `"SHA256:" + base64(SHA-256(public key blob))` without padding, the OpenSSH
  format the SDK produces (`lib.rs:38`). SHA-256 comes from CryptoKit. No new algorithm, but the
  blob parsing is security-relevant input handling and needs known-answer tests against
  `ssh-keygen -lf`.
- The public key blob can be read from an `openssh-key-v1` private key without decrypting it (the
  container stores public keys in clear). So import of *unencrypted* OpenSSH keys needs only
  base64 and length-prefixed parsing.
- Encrypted OpenSSH keys need `bcrypt_pbkdf` and AES-CTR. `bcrypt_pbkdf` is not in Apple's
  frameworks; implementing it would be hand-rolled crypto (prohibited by §III) or a new dependency
  (needs a Constitution amendment). Official clients decrypt and store the unencrypted key; Prizm
  would have to reject encrypted keys.
- PKCS#8/PEM keys need ASN.1 parsing and conversion to OpenSSH format (Ed25519 and RSA only).
- Ed25519 generation is possible with CryptoKit `Curve25519.Signing`, plus writing the
  `openssh-key-v1` container. RSA generation would use `SecKeyCreateRandomKey`.

**Decision (2026-10-29): C now, B as its own change (`ssh-key-import-and-generation`).** C is the
smallest change that stops the data loss, matches the iOS app, and needs no new crypto-adjacent code
under P0 time pressure. B gets its own design and security review. B is committed work, not an
option: it covers generation as well as import, because no server generates keys (Context above).

`ItemType` gains `isCreatable` (false for `.sshKey`); the New Item menu iterates
`ItemType.allCases.filter(\.isCreatable)`, and `VaultBrowserViewModel.createItemType` refuses a type
that is not creatable, as it refuses any type in Trash. The sidebar type filter still lists SSH keys.

### D5. Comments and tests

The false comments in `CipherMapper.toRawSSHKey`, `SSHKeyEditForm` and `DraftSSHKeyContent` are
replaced with the actual rule and a link to `vaultwarden/src/db/models/cipher.rs:298-308` (§VII).
`test_reverseMapper_sshKeyRoundTrip` keeps testing the create path (no fingerprint is sent, because
Prizm creates no SSH keys); new tests pin the edit path.

## Risks / Trade-offs

- **[Medium] Users lose a feature** (create, edit key text). → Release note explains why and points
  to official apps. The removed paths produced broken items on every Vaultwarden version with SSH
  keys (1.33.0 and later). On the official server they work today, apart from the missing
  fingerprint, so option C removes something that works there. The loss is temporary:
  `ssh-key-import-and-generation` brings creation back. Ship the two close together.
- **[Low] Items created by Prizm on the official server have no fingerprint.** They stay that way
  (D1 keeps `nil`) and remain editable. → Repair in an official client, or by
  `ssh-key-import-and-generation`, which fills in a missing fingerprint on the next save (its D5).
- **[Low] The change reverses two earlier decisions** (`edit-vault-items` editable key fields and
  the SSH creation of `882dede`). → The PR text names both.

## Open Questions

1. ~~Option C plus read-only key fields, or A or B now?~~ Decided 2026-10-29: C now, then B as
   `ssh-key-import-and-generation`. Nothing is left to ask.
2. Should D3 also apply to items that are complete but whose fingerprint does not match the public
   key? Prizm cannot check that without B; deferred to `ssh-key-import-and-generation` (its Open
   Question 2).
