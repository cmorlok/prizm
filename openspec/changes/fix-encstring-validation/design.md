# Design

## Context

### Official behaviour

Sources at HEAD 2026-10-23.

- **Type table.** `clients/libs/legacy-crypto/src/enums/encryption-type.enum.ts:3-18`: 0
  `AesCbc256_B64`, 2 `AesCbc256_HmacSha256_B64`, 7 `CoseEncrypt0`; asymmetric 3
  `Rsa2048_OaepSha256_B64`, 4 `Rsa2048_OaepSha1_B64`, 5 `Rsa2048_OaepSha256_HmacSha256_B64`, 6
  `Rsa2048_OaepSha1_HmacSha256_B64`. "These never occur in the same places that the symmetric ones
  would." Part counts (`:41-49`): 0→2, 2→3, 3→1, 4→1, 5→2, 6→2, 7→1. Type 1 was removed (`:6`).
- **SDK symmetric parse.** `sdk-internal/crates/bitwarden-crypto/src/enc_string/symmetric.rs:139-155`
  accepts only `("0", 2)`, `("2", 3)` and `("7", 1)`. IV and MAC go through `from_b64::<N>`, which
  fails unless the decoded length is exactly 16 or 32 (`enc_string/mod.rs:36-43`). Anything else is
  `Unparseable`.
- **SDK symmetric decrypt.** `symmetric.rs:479-511`: type 2 only with an `Aes256CbcHmacKey`, MAC
  checked first; type 0 returns `DecryptionNotImplementedForKey` even with a 32-byte key; any other
  combination is `WrongKeyType`.
- **Type 0 exists only for very old user keys**, decrypted with the unstretched master key
  (`sdk-internal/crates/bitwarden-crypto/src/keys/master_key.rs:176-200`). The SDK doc calls it
  "Deprecated and MUST NOT be used for encrypting as it is not authenticated" (`symmetric.rs:46`),
  and `decrypt_with_key` refuses it (`symmetric.rs:481-485`).
- **TS** refuses type 0 in every decrypt entry point: "Decryption of AesCbc256_B64 encrypted data
  is disabled." (`clients/libs/legacy-crypto/src/services/encrypt.service.implementation.ts:53-54,
  62-63, 71-72, 147-148, 168-169, 189-190`). Such items show as "Error: Cannot decrypt"
  (`decryptionFailure`, `clients/libs/common/src/vault/models/view/cipher.view.ts:78`).
- **Legacy accounts** (user key missing or type 0): official clients refuse login with
  "legacyEncryptionUnsupported" (`clients/libs/auth/src/angular/login/login.component.ts:424-432`).

### How type 0 can still arise

- The official server accepts type 0 on write: `EncryptedStringAttribute` validates the shape of
  type 0 but does not reject it (`server/src/Core/Utilities/EncryptedStringAttribute.cs:24,66-77`).
- Vaultwarden does no EncString validation at all.
- No current official client writes type 0 (the SDK forbids it for encryption).

So a type-0 field in a vault comes from one of three sources: ancient data written before MACs
were added, a third-party client, or tampering. The last one is the threat that matters. A server
or anyone who can change stored data can rewrite `2.iv|ct|mac` as `0.iv|ct`, drop the MAC and flip
CBC bits, and a client that decrypts type 0 shows the altered value without noticing. Refusing
type 0 everywhere closes that, at the cost of not showing genuinely ancient fields, which official
clients do not show either. This is a security decision and an exception to the compatibility
rule (`FIX-ORDER.md`).
- **Org keys (SDK).** `enc_string/asymmetric.rs:87-112` parses `("3",1)`, `("4",1)`, `("5",2)`,
  `("6",2)`. `decapsulate_key_unsigned` (`:250-275`) uses OAEP-SHA256 for 3 and 5 and OAEP-SHA1 for
  4 and 6. For 5 and 6 the HMAC part is parsed but not checked (`{ data, .. }`). The result must be
  32, 64 or more than 64 bytes (COSE) (`keys/symmetric_crypto_key.rs:681-700`). Current clients
  write type 4 (`asymmetric.rs:184-198`).
- **Private key import (SDK):** `RsaPrivateKey::from_pkcs8_der` (rsa crate).
- **Key stretching (SDK):** `stretch_key` = `hkdf_expand(key, "enc")` and `hkdf_expand(key, "mac")`
  (`keys/utils.rs:12-19`), where `hkdf_expand` is `Hkdf::<Sha256>::from_prk(prk).expand(info, …)`,
  that is HKDF-Expand without Extract (`util.rs:38-51`). Vector: `test_stretch_kdf_key`
  (`keys/utils.rs:55`).

### Prizm today

Checked 2026-10-30 on `fix/029-encstring-validation` (develop `ce678163`).

- `EncType` (`Prizm/Data/Crypto/EncString.swift:11-20`): 0, 2, 4 ("RSA-OAEP-SHA1, IV|ct|mac"), 6
  ("RSA-OAEP-SHA256, ct only").
- Parser (`:68-118`): type 0 needs 2 parts; types 2 and 4 need 3 parts; type 6 takes the first
  part. No IV or MAC length check.
- `decrypt(keys:)` (`:165-175`) verifies the MAC only `if encType == .aes256Cbc_HmacSha256_B64`,
  then calls `aesCbcDecrypt` for every type. `verifyMac` returns `true` when there is no MAC
  (`:144`).
- `aesCbcDecrypt` (`:219-248`) passes `iv.baseAddress` to `CCCrypt`, which reads 16 bytes.
  `AttachmentCrypto.swift:293-341` has a second, private AES pair for blobs (IV sliced to 16 bytes
  by `AttachmentBlobLayout`).
- **EncString decrypt call sites** (11):
  - `CipherMapper.swift`: `:258` `effectiveKeys` (item key; explicit type-2 guard at `:255`),
    `:307` `verifyKey` (guard at `:302`), `:796` `passwordRevisionDate` (save path), `:1019`
    `decryptRequired` (every field; also reached through `:885` with `try?`, and `:942`/`:961` on save)
  - `AttachmentMapper.swift:53` (file name; called twice per attachment because of the personal-key
    retry, `CipherMapper.swift:208`)
  - `AttachmentCrypto.swift:260` `decryptAttachmentKey`
  - `SyncRepositoryImpl.swift:219` (collection names)
  - `PrizmCryptoService.swift`: `:341` folders, `:461` user key, `:511` private key
- **What a decryption failure does today:**
  - item fields (name, notes, custom fields, login/card/identity/SSH values) and the item key: the
    item is excluded and counted (`decryptList` catch, `PrizmCryptoService.swift:~316`; org second
    pass `SyncRepositoryImpl.swift:236-259`);
  - attachment file name: only that attachment is dropped and logged, the item stays
    (`CipherMapper.swift:168-176`, after the personal-key retry);
  - attachment key: fails at download or Convert;
  - folder name: that folder is dropped and counted (`decryptFolders`);
  - collection name: dropped and logged, not counted (`SyncRepositoryImpl.swift:225-228`);
  - `passwordHistory`, `fido2Credentials`: never decrypted, kept verbatim;
  - `keyFingerprint` blank check (`CipherMapper.swift:885`, `try?`): a type-0 value counts as not
    blank and is kept.
- **Type-0 names today:** `CipherMapper.lastingEditBlock` sets `EditBlockReason.legacyEncryption`
  when the stored name has prefix `0` (`:348`, `usesLegacyEncryption` `:354-358`), and the item is
  listed read-only (main spec `vault-item-edit-roundtrip`). That works only because type 0 still
  decrypts. The save path also refuses a stored type-0 name (`FailClosedSaveTests.swift:177-187`).
- `decryptSymmetricKey` (`PrizmCryptoService.swift:445-488`) has no type check, only a debug log of
  the prefix.
- `unwrapOrgKey` (`:541-585`) accepts only `"4."` via `parseType4EncString` (`:594-606`), uses
  `.rsaEncryptionOAEPSHA1`, requires 64 bytes, and throws `.invalidEncUserKey`. A failing org is
  logged at `.fault` (`SyncRepositoryImpl.swift:186`), not listed (`:196-200`), and its items are
  counted as failed (`:243-247`). Errors are `PrizmCryptoServiceError` (`PrizmCryptoService.swift:11-26`);
  there is no `OrgKeyError`.
- `stripPKCS8Header` (`:620-665`): long-form lengths of any byte count, no check that
  `idx + length` stays inside the buffer before `index(_:offsetBy:)` and slicing. It runs once per
  organization inside the loop.
- `hkdfExpand` (`:432-437`): `HMAC<SHA256>(key: prk, data: info || 0x01)`, one block. Comment
  (`:410-419`) says CryptoKit's HKDF "performs full HKDF (Extract + Expand)" and "must NOT be used".
  CryptoKit also offers `HKDF<SHA256>.expand(pseudoRandomKey:info:outputByteCount:)` (macOS 11+).
  `SECURITY.md:57` says "CryptoKit `HKDF<SHA256>`". No test compares `stretchKey` with a known
  answer.
- Tests that rely on today's behaviour: `EncStringTests.swift:14-24` (type 0 parse), `:59-67`
  (three-part type 4), `AttachmentCryptoTests.swift:163-165` (NIST AES vector run through a type-0
  string), `EffectiveKeyReadTests.swift:247-248` (type-0 item key decrypts),
  `FailClosedSaveTests.swift:166-169` (type-0 name decrypts before the key check), and the tests of
  the type-0 read-only display (`EditGuardTests` only parses type 0 and stays).

## Goals / Non-Goals

**Goals**
- No AES decryption without a verified MAC, on any path.
- Parsing at least as strict as the SDK's. Nothing the SDK can decrypt is rejected.
- Org keys: no change for type 4; types 3, 5 and 6 fail with a typed error that the sync summary
  can report, never silently.
- No crash on malformed input.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Symmetric decrypt is type 2 only

`EncString.decrypt(keys:)` throws `EncStringError.unsupportedEncType` for anything but type 2,
before touching the key. MAC verification stays first and constant-time. `verifyMac` no longer
returns `true` for a missing MAC; it is private and only called for type 2.

Type 0 is never decrypted, on any path. An item with a type-0 field fails as a whole and, with
`fix-sync-decoding-resilience`, is shown as a "Can't decrypt this item" placeholder (its D3/D5),
the equivalent of the official "Error: Cannot decrypt".

`decryptSymmetricKey` (user key) gets one explicit type check (type 2 only) before `decrypt`, so
`account-scope-and-unsupported-features` can map a type-0 user key to a named "legacy encryption"
message later. Until then a legacy account fails with `invalidEncUserKey`, the same message as a
wrong password (Risks). No type-0 path will be added, because official clients refuse such accounts
too.

The explicit type-2 guards in `CipherMapper` (`:255`, `:302`) become redundant; they stay as defence
in depth, and their comments say so.

**Type-0 names (interim of `fix-cipher-edit-data-loss`).** An item with a type-0 name now fails to
decrypt like any other type-0 field and is excluded, so the read-only display
(`EditBlockReason.legacyEncryption` from the sync path) no longer happens. `legacyEncryption` stays
for the save-time check of the stored record: an item cached from an earlier sync whose stored record
changed to a type-0 name must still not be saved. Its doc comment and the comment of
`usesLegacyEncryption` say this. The main-spec scenario is removed at archive (proposal).

**Rejected:** keep type 0 for "old vaults". The SDK and TS refuse it, so such fields are already
unreadable in official clients, and accepting it keeps the MAC-stripping attack open (Context).

### D2. Split the type table

- `EncType` (symmetric): `aesCbc256_B64 = 0` (parsed, never decrypted) and
  `aesCbc256_HmacSha256_B64 = 2`. COSE type 7 gets no case: like any unknown number it is refused at
  parse with `unsupportedEncType`, and its shape is not parsed (a named case would only be refused
  again). Comments quote the TS enum.
- The type prefix must be the literal decimal digits, without sign or leading zero, as the SDK
  matches the header string; `EncString.splitHeader` is the one header parser for symmetric and
  RSA EncStrings (code review 2026-10-30).
- `AsymmetricEncType`: 3, 4, 5, 6, used only by org-key unwrap.
- Parsing a `3.`–`6.` string as a symmetric `EncString` throws `unsupportedEncType`.

### D3. Strict lengths

Errors per case:
- IV not 16 bytes (type 2 or type 0) → `invalidIVLength`;
- wrong part count, bad base64, MAC not 32 bytes, ciphertext empty or not a multiple of 16 →
  `malformedEncString`;
- type 3–6, 7 or an unknown number → `unsupportedEncType`, at parse.

Type 0 is still parsed (2 parts, IV 16 bytes) so its error is precise and `usesLegacyEncryption` keeps
working, but it is never decrypted (D1).

As a second line of defence, the AES helpers throw (not trap) when `iv.count != kCCBlockSizeAES128`
or the key is not 32 bytes. This applies to both CommonCrypto pairs: the `EncString` helpers become
`internal`, and `AttachmentCrypto`'s private pair is replaced by calls to them, so there is one
guarded implementation.

### D4. Org keys: type 4 only, typed error for 3, 5 and 6

Prizm today accepts only type 4 (`parseType4EncString`, `PrizmCryptoService.swift:540-552`). Current
clients write type 4 (`asymmetric.rs:184-198`), and no server writer for 3, 5 or 6 was found. So
keeping type 4 only breaks nothing that works today. This change does not add decryption for the
other types.

- `unwrapOrgKey` parses the prefix into `AsymmetricEncType`. Type 4 must have exactly one part
  and is unwrapped with `.rsaEncryptionOAEPSHA1`, as today. The result must be 64 bytes
  (`invalidSymmetricKeyLength` otherwise).
- Types 3, 5 and 6 throw the new `PrizmCryptoServiceError.unsupportedOrgKeyType(Int)` before any RSA
  call. Any other prefix, or a type-4 string with extra parts, throws the new
  `PrizmCryptoServiceError.malformedOrgKey`.
- `SyncRepositoryImpl` logs the failure at `.error` (one organization failing is recoverable, per
  CLAUDE.md; it was `.fault`) through `ErrorLog.describe`, whose text names the type number and never
  key material. The org stays unlisted and its items are counted as failed, as today. With
  `fix-sync-decoding-resilience`, the sync summary reports the org as `orgKeyUnwrapFailed`.

**Rejected:** unwrap 3–6 as the SDK does. It needs RSA vectors made outside Prizm and adds a code
path for data no current writer produces. It can be added if task 5.1 or a user report finds such
keys.

### D5. Keep the DER stripper, add bounds

Security.framework's `SecKeyCreateWithData` needs PKCS#1, and no Apple API takes PKCS#8 RSA keys.
The stripper stays (it parses framing, it is not a cryptographic algorithm) with these checks:
long-form length at most 4 bytes, `length ≤ remaining`, each
skip done with `index(_:offsetBy:limitedBy:)`, and the OCTET STRING must end inside the outer
SEQUENCE. Any failure throws a new `PrizmCryptoServiceError.malformedPrivateKey` (not the user-key
error). The AlgorithmIdentifier is checked to be `rsaEncryption` (OID 1.2.840.113549.1.1.1). The
header is stripped inside `unwrapOrgKey`, once per organization, as today: stripping it once before
the loop would change the `PrizmCryptoService` protocol for a logging detail, and a malformed key
then logs one error per organization, which is acceptable.

**Rejected:** a third-party ASN.1 library. A new dependency for ~40 lines of framing checks does
not pass §VI.

### D6. HKDF: keep, fix the documentation

The single-block HKDF-Expand stays. It is 3 lines and matches the SDK. The comment is corrected:
CryptoKit does offer Expand-only (`HKDF<SHA256>.expand`), and the reason to keep the current code
is that it is already reviewed and needs no change. A test asserts equality with
`HKDF<SHA256>.expand` and with the SDK `test_stretch_kdf_key` vector. SECURITY.md:57 is changed to
"HKDF-Expand (RFC 5869 §2.3), HMAC-SHA256 from CryptoKit".

**Rejected (for now):** switch to `HKDF<SHA256>.expand`. Equally valid and arguably closer to §III
("no hand-rolled algorithms"); the test in D6 makes the switch a one-line follow-up if the
maintainer prefers it (Open Question 1).

## Risks / Trade-offs

- **[Medium] Items with type-0 fields are no longer readable in Prizm.** → They are already
  unreadable in official clients ("Error: Cannot decrypt"). With `fix-sync-decoding-resilience`
  they show as placeholders. Deliberate: see Context, "How type 0 can still arise".
  **Rig count (task 5.1, 2026-10-30):** every EncString in the Vaultwarden 1.37.4 rig database
  (written by the browser extension, the `bw` CLI and Prizm) and in 9 snapshots: no type 0, no type
  3, 5 or 6. The live database holds 419 type-2 values and 9 organization keys, all type 4; all
  419 type-2 values pass the new length rules (IV 16, MAC 32, ciphertext non-empty and a multiple
  of 16), so the stricter parser refuses none of them. Counted read-only with a script that prints
  counts only.
- **[Low] Stricter parsing rejects strings Prizm accepted before** (wrong IV length). → Such strings
  cannot come from a correct client; the SDK rejects them too.
- **[Low] An org with a type-3/5/6 key stays unavailable.** → Same as today, but now reported with
  the type. Decryption can be added later if such keys are found (D4).
- **[Low] A legacy account (type-0 user key) sees the wrong-password message** until
  `account-scope-and-unsupported-features` names it (D1). Such accounts cannot sign in today either.
- **[Low] A type-0 attachment key** makes Open, Save and Convert fail with an error; nothing is
  decrypted and nothing crashes (task 1.5).

## Open Questions

1. Should the HKDF helper be replaced by CryptoKit `HKDF<SHA256>.expand` (D6)? The audit brief
   says keep; the maintainer may prefer the switch for §III.
2. Does any live Bitwarden or Vaultwarden data still contain type-3/5/6 org keys or type-0 fields?
   Not knowable from source (audit 02, "Not verified").
