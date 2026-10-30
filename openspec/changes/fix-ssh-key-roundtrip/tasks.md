# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
Decided 2026-10-29: option C and read-only key fields, then `ssh-key-import-and-generation`
brings key creation back.

## 1. Confirm server behaviour (0.25–0.5 d)

- [ ] 1.1 On the rig (Vaultwarden 1.37.4): create an SSH key in the web vault; send a PUT without `keyFingerprint` with a scripted request; confirm that `/sync` then returns `sshKey: null` and that the database row still has the private and public key. Record in design.md, Context.
- [ ] 1.2 Bitwarden self-hosted: not available (milestone rule: Vaultwarden 1.37.4 only); the official server is source-reviewed (design Context). Record that.

## 2. Keep fingerprint, read-only key fields (0.5–0.75 d)

- [ ] 2.1 Test: an edit's PUT body carries `keyFingerprint`, and it decrypts to the original value with the item's effective key; private and public key are unchanged.
- [ ] 2.2 Test: a round trip of an edit (map → draft → `toRawCipher(_:overlaying:)` → map) keeps private key, public key and fingerprint identical.
- [ ] 2.3 D1 needs no code: `fix-cipher-edit-data-loss` sends the stored `keyFingerprint` back. Keep only the tests; correct the comment of `test_reverseMapper_sshKeyRoundTrip` (create path, D5).
- [ ] 2.4 Make `DraftSSHKeyContent.privateKey` and `publicKey` `let` (D2); `SSHKeyEditForm` shows read-only rows (`FieldRowView`) with copy through the app's clipboard service; DesignSystem tokens only.
- [ ] 2.5 UI check (in the batch's UI run, with Christian's approval, or by hand): open an SSH key's edit sheet; the key rows are not editable; reveal and copy of the private key work.

## 3. No edit for SSH items without key data (0.25–0.5 d)

- [ ] 3.1 Failing test: `SSHKeyContent.hasKeyMaterial` is false when private or public key is nil or empty, true otherwise (fingerprint may be nil).
- [ ] 3.2 Failing tests: `editBlock(for:)` is `incompleteSSHKey` for a type 5 record with `sshKey` absent or null, or with a missing or empty private or public key; `map` sets it for keys that decrypt to empty; the message is plain language with a next step.
- [ ] 3.3 Implement D3 (`EditBlockReason.incompleteSSHKey`, mapper). The edit guard covers every Edit entry point and the save path (existing tests).

## 4. Remove SSH key creation (0.25 d)

- [ ] 4.1 Failing test: `ItemType.isCreatable` is false only for `.sshKey`; `VaultBrowserViewModel.createItemType` refuses `.sshKey`.
- [ ] 4.2 Filter the New Item menu by `isCreatable`. `DraftVaultItem.blank(type: .sshKey)` stays (unreachable from the UI; `ssh-key-import-and-generation` uses it again).
- [ ] 4.3 Replace the false comments (D5).

## 5. Release (0.25–0.5 d)

- [ ] 5.1 Live check on the rig: edit name and notes of an SSH key created in the web vault; the web vault still shows all three fields afterwards.
- [ ] 5.2 Mandatory security review: key material is never altered or dropped on write; no key text in logs.
- [ ] 5.3 CHANGELOG "Fix": editing an SSH key item no longer hides it on Vaultwarden or removes its fingerprint. "Removed": creating SSH keys and editing key text in Prizm, until import or generation is supported; use a Bitwarden app for that. Known issue: SSH keys created by earlier Prizm versions are hidden on Vaultwarden and lack a fingerprint on Bitwarden; recreate them in a Bitwarden app.
- [ ] 5.4 At archive time, update `openspec/specs/list-column-header/spec.md` (New Item menu types).
- [ ] 5.5 `/code-review`, `openspec validate fix-ssh-key-roundtrip --type change --strict`, `/opsx:verify`.
- [ ] 5.6 Archive the change (at the end of the batch, in PR order).
