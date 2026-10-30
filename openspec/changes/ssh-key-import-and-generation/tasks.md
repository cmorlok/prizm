# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).
Lane B: before coding, a fresh agent challenges proposal, design and spec once; a security review is
mandatory. Depends on `fix-ssh-key-roundtrip`. Upstream contact needs Christian's go-ahead.

## 1. Domain types, fingerprint, known answers (0.5–0.75 d)

- [ ] 1.0 Spec challenge by a fresh agent (2026-10-30): findings adopted into D4–D7 and the spec.
- [ ] 1.1 Produce the known-answer vectors with the local OpenSSH tools (D8): at least three Ed25519 keys, with the `ssh-keygen` command, its version, and the output of `-y` and `-l` recorded in the fixtures README. No fixture comes from the SDK.
- [ ] 1.2 Failing tests: `SSHKeyService.fingerprint(forPublicKey:)` equals the recorded `ssh-keygen -l` output for every vector; it returns `nil` for text that is not `<type> <base64> [comment]` or whose blob names another type. Compare only the `SHA256:` token of `ssh-keygen -l`.
- [ ] 1.3 Add `SSHKeyMaterial` (redacted description), `SSHKeyError` and `protocol SSHKeyService` to Domain (Foundation only); a test asserts the description contains no key text.
- [ ] 1.4 Implement `fingerprint(forPublicKey:)` in `SSHKeyServiceImpl` (Data, CryptoKit SHA-256, unpadded base64).

## 2. Generation (0.75–1 d)

- [ ] 2.1 Failing tests: `generate()` returns three non-empty values; the public key text is `ssh-ed25519 <base64>`; the fingerprint equals `fingerprint(forPublicKey:)`; two calls differ.
- [ ] 2.2 Failing test: the generated private key passes the importer (task 3) and round-trips to the same public key and fingerprint.
- [ ] 2.3 Implement the `openssh-key-v1` writer (D3): cipher and kdf `none`, equal check integers, padding `1, 2, 3, …`, 70-column armour.
- [ ] 2.4 Check several generated keys with OpenSSH (`ssh-keygen` in the devcontainer, or on the Mac): `ssh-keygen -y -f` prints the public key text and `ssh-keygen -l -f` the fingerprint. Record the result in design.md, D3.

## 3. Import and refusals (1–1.5 d)

- [ ] 3.1 Failing tests, one per vector: accepted keys (comment, empty comment, CRLF, no trailing newline); `notOpenSSHKey`; `passphraseProtected`; `unsupportedFormat` (PEM, PKCS#8, PuTTY, two keys in one file); `unsupportedKeyType` (RSA, ECDSA); `securityKey` (`sk-ssh-ed25519@openssh.com`); `damaged` (wrong check integer, bad padding, trailing bytes); `inconsistent` (outer public key differs from inner; public key differs from the one derived from the seed).
- [ ] 3.2 Failing test: a valid key's decoded bytes cut at every byte and re-armoured are refused (D4 says which error per region); none crashes. Inputs above 16 KiB are refused.
- [ ] 3.3 Implement the bounds-checked reader and checks 0–10 of D4, in that order. Store a new armour of the checked bytes.
- [ ] 3.4 Failing test: no error or description contains key text.

## 4. Create sheet (0.75–1 d)

- [ ] 4.1 Failing view-model tests: opening the sheet generates a key; "Generate new key" changes all three fields; a refused import keeps the current key and sets the message; Save is enabled only with all three fields.
- [ ] 4.2 Failing test: the create request carries `privateKey`, `publicKey` and `keyFingerprint`, all encrypted with the item's effective key (`fix-org-key-required-on-write`, `per-item-key-on-create`).
- [ ] 4.2a `DraftSSHKeyContent.replace(with:)`; `ItemEditViewModel` gets `SSHKeyService`; the key generated on open is the starting state (D6). File import reads at most 16 KiB + 1 bytes through the security-scoped URL; a file URL on the pasteboard is imported as a file (D4).
- [ ] 4.3 Implement the sheet: read-only rows as in `fix-ssh-key-roundtrip` D2, "Generate new key", "Import key…" with "From clipboard" and "From file…" (`fileImporter`). Delete the `ItemType.isCreatable` filter and its tests; the New Item menu lists all five types again.
- [ ] 4.4 Accessibility (§VIII): labels and copy hints on the rows (as `fix-ssh-key-roundtrip` D2), labelled actions, the import error announced when shown. Check the labels in an XCUITest.
- [ ] 4.5 XCUITest journey: New Item → SSH Key → generate → name → save; the item appears with all three fields. (No test uses a system-wide shortcut.) Run in the batch's UI run, with Christian's approval.

## 5. Fingerprint backfill and release (0.5–0.75 d)

- [ ] 5.1 Failing mapper tests: a create sends the computed fingerprint and refuses a draft fingerprint that differs; an edit of an item with a public key and no or a blank fingerprint sends the computed one; an item with a fingerprint sends it unchanged, also when it differs from the computed one; an unparsable public key sends none (D5).
- [ ] 5.2 Implement D5 in `CipherMapper.toRawSSHKey`.
- [ ] 5.3 Live check on the rig (Vaultwarden 1.37.4 and, if available, Bitwarden): create a key in Prizm and open it in the web vault; import a key made with `ssh-keygen` and compare the three fields; edit the name and confirm the key stays.
- [ ] 5.4 Mandatory security review: untrusted-input parsing (D4), no key text in logs or errors, no new dependency, Data-layer-only imports.
- [ ] 5.5 CHANGELOG "Added": SSH keys can be generated and imported again, and a missing fingerprint is filled in. Note that passphrase-protected, RSA and ECDSA keys are not yet importable.
- [ ] 5.6 At archive time, restore `openspec/specs/list-column-header/spec.md:10` (New Item menu lists "SSH Key").
- [ ] 5.7 Decide Open Question 1 (RSA and ECDSA import) from the live results; if yes, write a follow-up change, do not extend this one.
- [ ] 5.8 `/code-review`, `openspec validate ssh-key-import-and-generation --type change --strict`, `/opsx:verify`.
- [ ] 5.9 Archive the change (at the end of the batch, in PR order, after `fix-ssh-key-roundtrip`).
