# Proposal

## Why

**Criticality:** P2 (Medium: a feature that `fix-ssh-key-roundtrip` removes until this change exists)
**Findings:** option B of `fix-ssh-key-roundtrip` (design D4); the "server derives the SSH fingerprint"
premise in the code audit (`.planning/research/source-review/code-audit/SUMMARY.md`, "Pattern: why
this happened").

`fix-ssh-key-roundtrip` stops Prizm from destroying SSH keys. To do that it takes SSH key creation
out of the New Item menu, because a key created in Prizm today has no fingerprint, and Vaultwarden
hides any SSH item without one. This change brings creation back, done properly.

**No server generates or derives SSH key data.** Both servers store what the client sends
(`fix-ssh-key-roundtrip`, design Context). Official clients therefore do two things in the client:
they generate an Ed25519 key, and they import an existing key, and both fill private key, public key
and fingerprint together. Prizm has neither. So the work is:

- **Generate** a new key pair on the Mac and write all three fields.
- **Import** a key the user already has (clipboard or file), reading the public key out of it and
  computing the fingerprint, and refusing input it cannot check.

### Decided: no Bitwarden SDK

The official clients use the Bitwarden SDK for this. Prizm does not, and this is settled so it is not
reopened (design D1): the SDK's Swift package declares iOS only, `sdk-internal` states that it is not
intended for public use and may change without warning, it is GPL-3.0 or the Bitwarden SDK License
against Prizm's MIT, and the Constitution (§III) prohibits third-party crypto without an amendment.
Apple's frameworks cover what is needed.

## What Changes

- **New SSH keys are generated.** New Item → SSH Key opens the create sheet with a freshly generated
  Ed25519 key already filled in: private key (masked, with reveal and copy), public key and
  fingerprint, all read-only. "Generate new key" replaces it.
- **Keys can be imported** from the clipboard or a file. Prizm accepts an unencrypted OpenSSH
  Ed25519 private key, checks it, and fills the three fields. Anything else is refused with a
  specific message (passphrase-protected, unsupported type, damaged, or inconsistent).
- **The fingerprint is computed**, in the OpenSSH form `SHA256:<unpadded base64>` of the public key.
- **A missing fingerprint is filled in on the next save** of an item that has a public key. An
  existing fingerprint is never replaced.
- **SSH key creation returns to the New Item menu.** The `isCreatable` filter that
  `fix-ssh-key-roundtrip` adds is removed again.

## Capabilities

### New Capabilities
- `ssh-key-creation`: generating and importing SSH keys, and computing their fingerprint.

### Modified Capabilities
- `ssh-key-integrity` (added by `fix-ssh-key-roundtrip`): the requirement "SSH keys cannot be
  created until Prizm can generate or import them" is removed.

At archive time, restore `openspec/specs/list-column-header/spec.md:10` (the New Item menu lists
"SSH Key"), which `fix-ssh-key-roundtrip` changes.

## Non-Goals

- **Passphrase-protected OpenSSH keys.** They need `bcrypt_pbkdf`, which Apple's frameworks do not
  have. Writing it by hand is prohibited (§III) and a dependency needs a Constitution amendment. The
  user removes the passphrase first (`ssh-keygen -p`); the error message says so.
- **PKCS#8 / PEM keys** (ASN.1 parsing and conversion).
- **RSA and ECDSA import and RSA generation** in this change. They are a possible second stage
  (design Open Question 1).
- **Repairing items Vaultwarden already hides.** The stored key data is on the server, but Prizm never
  receives it (`fix-ssh-key-roundtrip`, D3).
- An SSH agent, and using the SDK (design D1).

## Dependencies

- **Hard:** `fix-ssh-key-roundtrip` (read-only key fields, the incomplete-item rule, and the removal
  of creation that this change undoes). Ship the two close together.
- Soft, already landed: `fix-cipher-edit-data-loss` (`encryptedFor`, the effective-key rule),
  `harden-key-lifecycle-and-logging` and `clipboard-hardening` (the rules this change follows for
  secrets in memory, logs and the pasteboard).

## Impact

- **Domain:** `SSHKeyService` protocol and `SSHKeyMaterial` (private key, public key, fingerprint) in
  Foundation-only types; typed `SSHKeyError`.
- **Data:** `SSHKeyServiceImpl` (CryptoKit only): Ed25519 generation, `openssh-key-v1` writing and
  parsing, fingerprint. `CipherMapper.toRawSSHKey` fills a missing fingerprint.
- **Presentation:** create sheet for SSH keys, "Generate new key" and "Import key…" (clipboard, file
  picker); New Item menu lists SSH Key again.
- **App:** wires `SSHKeyServiceImpl` in `AppContainer`.
- **No new dependencies.** No entitlement change: the app already has
  `com.apple.security.files.user-selected.read-write`.
- **Security review: yes** (key material, untrusted input parsing, §III).

## Estimate

Ideal engineer-days, TDD included. Stage 1 only.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Domain types, protocol, fingerprint, public key text, known-answer tests | 0.5–0.75 d |
| 2 | Ed25519 generation and `openssh-key-v1` writer | 0.75–1 d |
| 3 | Import parser, validation, refusal paths | 1–1.5 d |
| 4 | Create sheet, import actions, accessibility, UI journeys | 0.75–1 d |
| 5 | Fingerprint backfill, security review, live check, CHANGELOG | 0.5–0.75 d |
| **Total** | | **3.5–5 d** |

A second stage (RSA and ECDSA import) would add about 1.5–2 d; it is not counted.
