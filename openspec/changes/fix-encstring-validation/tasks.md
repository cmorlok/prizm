# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV). This change has
no hard dependencies.

## 0. Checkpoint

- [x] 0.1 Spec challenge by a fresh agent (Lane B), 2026-10-30, against the code at develop `ce678163`. Done: 2 blockers (type-0 read-only display in `vault-item-edit-roundtrip`; tests that assert type-0 decryption), 7 should-fixes and 5 nits, all adopted into proposal, design (Context "Prizm today", D1–D5, Risks), specs and these tasks.

## 1. Failing tests for today's gaps (0.5 d)

- [ ] 1.1 Failing test: take a valid type-2 field, rewrite it as `0.<iv>|<ct>` (MAC dropped) and decrypt with the right key. Today it returns the plaintext; it must throw `unsupportedEncType`.
- [ ] 1.2 Failing test: `4.<iv>|<ct>|<mac>`, `6.<ct>` and `7.<x>` throw `unsupportedEncType` at parse, before any AES call.
- [ ] 1.3 Failing tests with the exact error per case (D3): 0-, 8- and 17-byte IV → `invalidIVLength`; 31- and 33-byte MAC, empty ciphertext, 15-byte ciphertext, two parts, bad base64 → `malformedEncString`. None reaches `CCCrypt`.
- [ ] 1.4 Failing tests on the sync path: a cipher whose `login.password` is type 0 is excluded and counted in `failedCount`, in the personal and in the org pass; a type-0 attachment `fileName` drops only that attachment (item listed, error logged), also on the personal-key retry; a type-0 folder name drops that folder (counted); a type-0 collection name drops that collection (logged).
- [ ] 1.5 Failing test: an attachment whose key is type 0 makes Open and Convert fail with an error; nothing is decrypted.

## 2. Type table, parser, decrypt (0.5–1 d)

- [ ] 2.1 Split `EncType` (0, 2) and `AsymmetricEncType` (3, 4, 5, 6) with comments quoting the TS enum (design.md D2). Remove the RSA cases from the symmetric parser; type 7, like any unknown number, is refused at parse. One header parser (`EncString.splitHeader`) takes only the literal digits.
- [ ] 2.2 Strict lengths in the parser (D3). The `EncString` AES helpers become `internal` and throw on a wrong IV or key length; `AttachmentCrypto` uses them instead of its private pair.
- [ ] 2.3 `decrypt(keys:)` accepts type 2 only; `verifyMac` is private and never returns `true` for a missing MAC (D1). §VII comment: security goal (no unauthenticated CBC decryption, padding oracle), SDK `symmetric.rs:479-511`, what is deliberately not supported (type 0, type 7). `decryptSymmetricKey` gets its explicit type-2 check. The comments of the `CipherMapper` type-2 guards (`:255`, `:302`) say they are defence in depth.
- [ ] 2.4 Update existing tests: `EncStringTests` type-0 parse (parse still works, decrypt throws); remove the three-part type-4 test; `AttachmentCryptoTests` NIST AES vector calls `EncString`'s AES helper directly; `EffectiveKeyReadTests` type-0 item key now throws `unsupportedEncType`; `FailClosedSaveTests.testStoredNameWithoutMAC_failsTheKeyCheck` without the plaintext assertion. Tasks 1.1–1.5 pass.
- [ ] 2.5 Type-0 names: tests of the read-only display through sync become "excluded and counted"; `EditBlockReason.legacyEncryption` stays for the save-time stored-record check (D1). Update its doc comment and the comment of `usesLegacyEncryption`.

## 3. Org key type check (0.25 d)

- [ ] 3.1 Failing tests (reuse the existing `OrgKeyCryptoKATTests` type-4 vector): type 4 still unwraps to the same 64 bytes; `3.<x>`, `5.<x>|<y>` and `6.<x>|<y>` throw `PrizmCryptoServiceError.unsupportedOrgKeyType` with the type number and make no RSA call; type 4 with an extra part, type 2 and type 7 throw `.malformedOrgKey`; a 32-byte result is rejected with `invalidSymmetricKeyLength`.
- [ ] 3.2 Implement D4 in `unwrapOrgKey` with a small parser for `AsymmetricEncType`. §VII comment: why only type 4 is unwrapped, and that 3/5/6 are rejected on purpose. `SyncRepositoryImpl` logs at `.error` with the type number, never key material; test that the org is not listed and its items are counted.

## 4. DER parser bounds (0.5 d)

- [ ] 4.1 Failing tests: truncated key, length larger than the buffer, 5-byte and 0x80 (indefinite) length, wrong AlgorithmIdentifier OID, OCTET STRING past the outer SEQUENCE. Each throws `malformedPrivateKey` and does not crash.
- [ ] 4.2 Implement D5 in `stripPKCS8Header` (once per organization, inside `unwrapOrgKey`). The existing `OrgKeyCryptoKATTests` still pass.

## 5. HKDF, review, docs (0.5 d)

- [ ] 5.1 Count type-0 and type-3–6 strings in the rig vault (fields and org keys, Vaultwarden 1.37.4) and record the result in design.md, Risks.
- [ ] 5.2 New test: `stretchKey` equals CryptoKit `HKDF<SHA256>.expand(pseudoRandomKey:info:outputByteCount:)` and the SDK `test_stretch_kdf_key` vector (`keys/utils.rs:55`). Correct the comment at `PrizmCryptoService.swift:410-419` (D6).
- [ ] 5.3 Mandatory `/security-review`: every decrypt call site (design.md Context, 11 sites) goes through the type-2-only path; no AES decryption before MAC verification; org-key types; parser bounds; no key bytes in logs.
- [ ] 5.4 SECURITY.md: HKDF row (`:57`) corrected; a short "Accepted EncString types" paragraph (type 2 for data; type 4 for org keys only; 0, 3, 5, 6 and 7 refused, with the reason for type 0 from design.md Context).
- [ ] 5.5 CHANGELOG "Security": Prizm never decrypts vault data that lacks an integrity check (EncString type 0, or mislabelled RSA types), and checks IV and MAC lengths; items with such data are no longer shown. "Fixed": a malformed private key no longer crashes the app; an organization key in an unsupported format is logged with its type.
- [ ] 5.6 At archive: remove the scenario "Item with a name in an old encryption format" from `openspec/specs/vault-item-edit-roundtrip/spec.md` by hand (proposal, Modified Capabilities).
- [ ] 5.7 `/code-review`, `openspec validate fix-encstring-validation --type change --strict`, `/opsx:verify`.
- [ ] 5.8 Archive the change (at the end of the batch, in PR order).
