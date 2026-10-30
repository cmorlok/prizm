# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
Decided 2026-10-29: option C and read-only key fields, then `ssh-key-import-and-generation`
brings key creation back.

## 1. Confirm server behaviour (0.25–0.5 d)

- [x] 1.1 On the rig (Vaultwarden 1.37.4): create an SSH key in the web vault; send a PUT without `keyFingerprint` with a scripted request; confirm that `/sync` then returns `sshKey: null` and that the database row still has the private and public key. Record in design.md, Context. Done: rig run `20261030T113852Z`, check `022.1.1`: PUT without `keyFingerprint` answers HTTP 200, `/sync` then returns `sshKey: null`, the database row keeps the private and public key and has no fingerprint. The key was created with the official `bw` CLI 2026.9.1, which stands in for the web vault (same SDK). Recorded in design.md, Context.
- [x] 1.2 Bitwarden self-hosted: not available (milestone rule: Vaultwarden 1.37.4 only); the official server is source-reviewed (design Context). Record that. Done: recorded in design.md, Context.

## 2. Keep fingerprint, read-only key fields (0.5–0.75 d)

- [x] 2.1 Test: an edit's PUT body carries `keyFingerprint`, and it decrypts to the original value with the item's effective key; private and public key are unchanged. Done: `SSHKeyIntegrityTests.testEdit_sendsStoredFingerprintAndUnchangedKeys`. It passes before the fix as well, because `fix-cipher-edit-data-loss` already sends the fingerprint back (task 2.3).
- [x] 2.2 Test: a round trip of an edit (map → draft → `toRawCipher(_:overlaying:)` → map) keeps private key, public key and fingerprint identical. Done: the same test maps the request back and compares all three values.
- [x] 2.3 D1 needs no code: `fix-cipher-edit-data-loss` sends the stored `keyFingerprint` back. Keep only the tests; correct the comment of `test_reverseMapper_sshKeyRoundTrip` (create path, D5). Done: the comment now says that the create path sends no fingerprint.
- [x] 2.4 Make `DraftSSHKeyContent.privateKey` and `publicKey` `let` (D2); `SSHKeyEditForm` shows read-only rows (`FieldRowView`) with copy through the app's clipboard service; DesignSystem tokens only. Done: commit `2d0f57cb`. The form has no raw font or spacing literals.
- [x] 2.5 UI check (in the batch's UI run, with Christian's approval, or by hand): open an SSH key's edit sheet; the key rows are not editable; reveal and copy of the private key work. Done: hand check by Christian on 2026-10-30 (rig, build of the batch integration branch, a key created in the SSH create sheet): the rows can't be edited, Reveal and Copy work, VO-Space on a row copies it. VoiceOver reads the rows as text, without "not editable": they are not text fields, as in the detail view (accepted).

## 3. No edit for SSH items without key data (0.25–0.5 d)

- [x] 3.1 Failing test: `SSHKeyContent.hasKeyMaterial` is false when private or public key is nil or empty, true otherwise (fingerprint may be nil). Done: `SSHKeyIntegrityTests.testHasKeyMaterial`. Red `20261030T082240Z` (compile: `hasKeyMaterial` missing).
- [x] 3.2 Failing tests: `editBlock(for:)` is `incompleteSSHKey` for a type 5 record with `sshKey` absent or null, or with a missing or empty private or public key; `map` sets it for keys that decrypt to empty; the message is plain language with a next step. Done: `testEditBlock_sshKeyAbsentOrNull_isIncompleteSSHKey`, `testEditBlock_missingOrEmptyKeyText_isIncompleteSSHKey`, `testMap_keyTextThatDecryptsToEmpty_isIncompleteSSHKey`, `testCompleteKeyWithoutFingerprint_isEditable`, `testIncompleteSSHKeyMessage`, and `EditGuardTests.testReasonMessages_arePlainLanguageWithANextStep`. Red in the same run `20261030T082240Z`.
- [x] 3.3 Implement D3 (`EditBlockReason.incompleteSSHKey`, mapper). The edit guard covers every Edit entry point and the save path (existing tests). Done: commit `2d0f57cb`. Green `20261030T082423Z` (1101 unit tests); after the squash, the per-commit run on `2d0f57cb` `20261030T133731Z` (1101 passed, 0 failed). The existing guard tests (`EditGuardTests.testFullSaveOfABlockedItem_throwsItemNotEditableAndSendsNothing`, `testBlockedItem_stillStarsAndMovesThroughPartial`) cover the save path and the actions that stay available.

## 4. Remove SSH key creation (0.25 d)

- [x] 4.1 Failing test: `ItemType.isCreatable` is false only for `.sshKey`; `VaultBrowserViewModel.createItemType` refuses `.sshKey`. Done: `SSHKeyIntegrityTests.testOnlySSHKeysAreNotCreatable`, `VaultBrowserViewModelTrashTests.testCreateItemType_refusesSSHKey`. Red `20261030T082240Z`.
- [x] 4.2 Filter the New Item menu by `isCreatable`. `DraftVaultItem.blank(type: .sshKey)` stays (unreachable from the UI; `ssh-key-import-and-generation` uses it again). Done: `VaultBrowserView` iterates `ItemType.allCases.filter(\.isCreatable)`; `blank(type:)` is unchanged.
- [x] 4.3 Replace the false comments (D5). Done: `CipherMapper.toRawSSHKey`, `SSHKeyEditForm`, `DraftSSHKeyContent` (property and type comment; the type comment was fixed after the review of 2026-10-30) and `MaskedEditFieldRow`.

## 5. Release (0.25–0.5 d)

- [x] 5.1 Live check on the rig: edit name and notes of an SSH key created in the web vault; the web vault still shows all three fields afterwards. Done: rig run `20261030T113852Z`, checks `prizm 022.5.1` (Prizm saved the new name and notes of a key created with the official CLI) and `022.5.1.bw` (`bw` shows the edited key with private key, public key and fingerprint present and unchanged). `bw` stands in for the web vault.
- [x] 5.2 Mandatory security review: key material is never altered or dropped on write; no key text in logs. Done: independent review 2026-10-30, no blockers; security note in design.md, "Review".
- [x] 5.3 CHANGELOG. Done, under "Unreleased": "Fix: an SSH key whose private or public key is missing (for example one that Vaultwarden hides) can no longer be edited in Prizm, so a save cannot overwrite the key stored on the server. Prizm says to repair it in a Bitwarden app." "Changed: the private key, public key and fingerprint of an SSH key are read-only in the edit sheet, as in the other Bitwarden apps; name, notes and custom fields stay editable." "Removed: creating SSH keys in Prizm, until Prizm can generate or import them: keys created in Prizm had no fingerprint, so Vaultwarden hid them. Create SSH keys in a Bitwarden app for now." "Known issue: SSH keys created by earlier Prizm versions are hidden on Vaultwarden and have no fingerprint on the Bitwarden server; recreate them in a Bitwarden app." (The task text's "editing no longer hides it or removes its fingerprint" was already fixed and listed by `fix-cipher-edit-data-loss`.)
- [x] 5.4 At archive time, update `openspec/specs/list-column-header/spec.md` (New Item menu types). Done in the archive commit: the menu lists the creatable types; SSH Key is not offered.
- [x] 5.5 `/code-review`, `openspec validate fix-ssh-key-roundtrip --type change --strict`, `/opsx:verify`. Done 2026-10-30: independent review (design.md "Review"); valid; `/opsx:verify`: no critical issues. Its warning, the stale "details are missing" scenario of `vault-item-edit-roundtrip` for SSH items, is fixed in the archive commit (main spec edit).
- [x] 5.6 Archive the change (at the end of the batch, in PR order).
