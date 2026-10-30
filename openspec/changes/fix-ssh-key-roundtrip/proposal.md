# Proposal

## Why

**Criticality:** P0 (Critical: destroys data now)
**Findings:** "Open: SSH key handling" in the plan review (`.planning/research/source-review/SUMMARY.md`,
section of that name), and the "server derives the SSH fingerprint" premise listed in the code audit
(`code-audit/SUMMARY.md`, "Pattern: why this happened").

**Prizm did not send the SSH key fingerprint.** Until `fix-cipher-edit-data-loss` (fork PR #40),
`toRawSSHKey` set `keyFingerprint: nil` on create and on every edit, with the comment that the
fingerprint "is auto-derived and not sent to the API — it is server-authoritative". An edit now sends
the stored fingerprint back; a create still sends none. No server derives it:

- **Vaultwarden** returns `sshKey: null` for any SSH item whose fingerprint, private key or public
  key is empty. So after *any* edit in Prizm (even of the name or notes) the key disappears from
  every client, Prizm included. SSH keys created in Prizm never show their key data anywhere.
- **Official server** stores what it gets. The fingerprint is lost; clients show the item without
  one.

**Editing the key text breaks the item.** The edit sheet lets the user change the private and
public key (`Prizm/Presentation/Vault/Edit/SSHKeyEditForm.swift`). Official clients never do:
the three fields are generated or imported together and shown read-only. A kept fingerprint would
then describe a different key.

**Editing a hidden key on Vaultwarden destroyed it.** When Vaultwarden hides an invalid SSH item
(`sshKey: null`), the stored key data still exists on the server. Before `fix-cipher-edit-data-loss`,
Prizm showed the item with empty fields, and a save wrote `null` over the stored private and public
key. That change now blocks the edit with a generic message ("Some of this item's details are
missing…"); an `sshKey` object with an empty private or public key is still editable.

### Origin of the current behaviour

**Wrong premise in a maintainer-specified change.**
- `edit-vault-items` (commit `88ff36e`, PR #8, 2026-03-23) has the goal "Allow users to edit any
  field on any of the five item types" and specifies the SSH edit sheet with "private key, public
  key, and notes editable, and the key fingerprint displayed as a read-only field"
  (`openspec/changes/archive/2026-03-23-edit-vault-items/specs/vault-item-edit/spec.md:35`).
- The code repeated "server-authoritative" (`CipherMapper.toRawSSHKey`, until PR #40), and still says
  "auto-derived from the private key by the server" (`SSHKeyEditForm.swift`, `DraftSSHKeyContent`);
  a test asserts the fingerprint is not sent (`CipherMapperReverseTests.test_reverseMapper_sshKeyRoundTrip`).
- SSH key creation was added in commit `882dede` (2026-03-24), and the create menu lists every type
  (`openspec/specs/list-column-header/spec.md:10`).

**This change alters behaviour specified earlier** (editable key fields, SSH key creation). Decided
2026-10-29: this is the interim fix that stops the data loss. Proper key generation and import follow
in `ssh-key-import-and-generation`, which brings SSH key creation back. The pull request text says
plainly that it reverses those two earlier decisions.

## What Changes

- **The fingerprint is kept on edit.** `fix-cipher-edit-data-loss` sends the stored fingerprint
  back as received; this change pins it with tests.
- **Key fields are read-only in the edit sheet.** Private key (masked, with reveal and copy),
  public key and fingerprint are shown but cannot be changed, as in the official clients. Name,
  notes, custom fields, folder and favorite stay editable.
- **SSH items without key data cannot be edited.** If the private or public key is missing (for
  example because Vaultwarden hid the key), Edit is disabled with the explanation "This SSH key is
  incomplete and can't be edited in Prizm. Open it in a Bitwarden app to repair it." Prizm never
  writes `null` over stored key data.
- **SSH key creation is removed temporarily** from the New Item menu and the create sheet, until
  `ssh-key-import-and-generation` lets Prizm generate or import keys with a computed fingerprint
  (option C in design.md). This is the only part of this change that is meant to be undone. The
  iOS app also offers no SSH key creation.

## Capabilities

### New Capabilities
- `ssh-key-integrity`: SSH key items keep private key, public key and fingerprint consistent and
  complete on every write.

### Modified Capabilities
_None in this change._ At archive time, update:
- `openspec/specs/list-column-header/spec.md:10` (New Item menu lists "SSH Key"), and
- the SSH scenario of the archived `edit-vault-items` spec, if it was synced into a living spec
  (`vault-item-edit` is not under `openspec/specs/` today; check at archive time).

## Non-Goals

- Generating SSH keys or importing them from a file or the clipboard (option B in design.md).
  This is the separate change `ssh-key-import-and-generation`, which depends on this one.
- Repairing SSH items that already lost their fingerprint or key data.
- An SSH agent.

## Dependencies

- None hard.
- **Overlap with `fix-cipher-edit-data-loss`.** That change copies the stored `keyFingerprint`
  back on every edit (its design D2 and D3) and refuses to edit an SSH item whose `sshKey` object is
  missing (edit-block reason `unmappable`, its design D4). This change owns the key-field rules, the
  item whose key text is missing or empty (design D3 here) and SSH key creation. That change has
  landed, so task 2.3 here is a regression test only.
- Soft: `fix-cipher-edit-data-loss` for `encryptedFor`, without which no SSH edit reaches
  Vaultwarden 1.37.4 at all.

## Impact

- **Data:** `CipherMapper.toRawSSHKey` sends the fingerprint; comments fixed.
- **Domain:** `DraftSSHKeyContent` key fields become `let`; `SSHKeyContent.hasKeyMaterial`;
  `ItemType` gains `isCreatable` (false for `.sshKey`).
- **Presentation:** `SSHKeyEditForm` read-only rows; Edit disabled for SSH items without key data
  (every Edit entry point); New Item menus filtered by `isCreatable`.
- **No new dependencies.**
- **Security review: yes** (vault write path for key material, §III).

## Estimate

Ideal engineer-days, TDD included. Option C (recommended).

| Step | Scope | Estimate |
|---|---|---|
| 1 | Confirm behaviour on both servers | 0.25–0.5 d |
| 2 | Keep fingerprint; read-only key fields | 0.5–0.75 d |
| 3 | Block edit of SSH items without key data | 0.25–0.5 d |
| 4 | Remove SSH key creation from menus | 0.25 d |
| 5 | Security review, CHANGELOG, maintainer note | 0.25–0.5 d |
| **Total** | | **1.5–2.5 d** |

Option B (import plus Ed25519 generation, separate change) is estimated at 3–5 d in design.md.
