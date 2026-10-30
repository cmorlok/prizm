# Proposal

## Why

**Criticality:** P1 (High)
**Findings:** C-04, C-05, C-07, C-11, C-17, C-18 (`02-crypto.md`)

Every encrypted field in a Bitwarden vault is an "EncString" such as `2.<iv>|<ct>|<mac>`. The
number says how it is encrypted. Prizm's parser trusts that number too much:

- **Missing MAC is accepted (C-04).** Prizm checks the MAC only for type 2
  (`Prizm/Data/Crypto/EncString.swift:165-175`). A string with type 0 (`0.iv|ct`, no MAC) is
  decrypted with the vault, org or item key without any authentication. So are strings labelled
  type 4 or 6, because Prizm treats them as symmetric too. A malicious or compromised server can
  rewrite a type-2 field as type 0, flip bits in the CBC ciphertext, and Prizm shows the altered
  value. It can also use decryption errors as a padding oracle. This works on every field, item
  key, folder and collection name, attachment key and the RSA private key. The official SDK and
  TS clients refuse type 0 for all of these.
- **Wrong type table (C-05).** Prizm calls type 4 "RSA-OAEP-SHA1 with IV, ciphertext and MAC" and
  type 6 "RSA-OAEP-SHA256, ciphertext only". In Bitwarden, 3 is OAEP-SHA256, 4 is OAEP-SHA1, 5 and
  6 are the same with an extra HMAC part, and 7 is COSE. The wrong labels are what let types 4 and
  6 reach AES decryption.
- **No length checks (C-11).** The IV is not checked to be 16 bytes nor the MAC 32 bytes. A short
  IV makes CommonCrypto read past the buffer. An empty IV becomes a NULL pointer, which CommonCrypto
  treats as an all-zero IV. The error `invalidIVLength` exists but is never thrown.
- **Org keys: only type 4 (C-07).** Organization keys in types 3, 5 or 6 are skipped, and that
  org's items disappear with only a log entry. The type-4-only rule itself breaks nothing: current
  clients write type 4 and no server writer for 3, 5 or 6 was found (design.md D4). The silent skip is the problem.
- **DER parser without bounds (C-17).** The PKCS#8 stripper (`PrizmCryptoService.swift:620-665`)
  does not check lengths before `index(_:offsetBy:)`. A malformed private key crashes Prizm.
- **HKDF documentation is wrong (C-18).** The stretch function is a hand-written single-block
  HKDF-Expand. Its comment says CryptoKit cannot do Expand-only, and SECURITY.md:57 says CryptoKit
  `HKDF<SHA256>` is used. Neither is true. The output is correct (it matches the SDK).

Users do not see a difference today unless their server is malicious or broken. The MAC bypass is
a real gap against the threat model in SECURITY.md (a server that cannot read the vault).

### Origin of the current behaviour

- Type 0 accepted: **wrong premise.** `EncString.swift:47`: "Type 0 — AES-256-CBC, no MAC.
  Deprecated but still appears in old vaults." (`fd32450`, 2026-03-16).
- Type 4/6 labels: **wrong premise.** Enum comments (`EncString.swift:16-19`) and the test comment
  "Type 4 format: 4.<iv_b64>|<ct_b64>|<mac_b64>" (`PrizmTests/Data/EncStringTests.swift:59`),
  same commit. The type-4/6 MAC bypass is an accidental side effect.
- Length checks: **accidental** (error case declared, never used).
- Org key types: partly **deliberate**. `openspec/changes/archive/2026-04-19-org-support/design.md:28`
  says OAEP-SHA1 "implements the Bitwarden org key unwrap exactly". Types 3/5/6 are accidental.
- DER parser: **deliberate** "minimal parser" (`PrizmCryptoService.swift:618-619`); bounds missing.
- HKDF: **deliberate** (comment at `PrizmCryptoService.swift:410-419`), with a wrong reason.
- Type-0 item names shown read-only: **deliberate interim** in `fix-cipher-edit-data-loss`
  (`EditBlockReason.legacyEncryption`, main spec `vault-item-edit-roundtrip`, scenario "Item with a
  name in an old encryption format"), which said it stays until this change refuses type 0.

## What Changes

- **Symmetric decryption accepts type 2 only.** Type 0 is never decrypted. Type 0, any RSA type
  and type 7 are refused with a typed error before any AES call. The item fails closed: with
  `fix-sync-decoding-resilience` it shows as a "Can't decrypt this item" placeholder, as official
  clients show "[error: cannot decrypt]"; before that lands it is excluded and counted, as with a
  MAC mismatch today. Type 0 arises only from ancient data, third-party clients or tampering
  (design.md, Context). This follows the compatibility rule agreed 2026-10-25 ("EncString type 0 is
  never decrypted") and ends the interim read-only display of type-0 names from
  `fix-cipher-edit-data-loss`.
- **`EncType` holds only symmetric types** (0, 2, 7) with correct comments. RSA types move to a
  separate `AsymmetricEncType` (3, 4, 5, 6) used only for org keys.
- **Strict parsing:** type 2 needs exactly 3 parts, a 16-byte IV, a non-empty ciphertext whose
  length is a multiple of 16, and a 32-byte MAC. Anything else is `malformedEncString`.
- **Org keys:** type 4 only, as today, now parsed strictly (exactly one part). Types 3, 5 and 6
  are recognised and rejected with the new error `PrizmCryptoServiceError.unsupportedOrgKeyType(Int)`;
  any other type with `.malformedOrgKey`. No decryption is added for 3, 5 or 6. The failure is logged
  with the type number at `.error` (recoverable), and the org's items are counted as failed; the
  sync summary of `fix-sync-decoding-resilience` will report the org by name.
- **DER parser:** every length is checked against the remaining bytes; malformed input throws.
- **HKDF:** kept as is. Its comment and SECURITY.md are corrected, and a known-answer test against
  the SDK's `stretch_key` vector and CryptoKit `HKDF<SHA256>.expand` is added.

## Capabilities

### New Capabilities
- `encstring-validation`: which EncString types Prizm decrypts, how it parses them, and how
  organization keys are unwrapped.

### Modified Capabilities
- `org-key-crypto`: "Organization symmetric keys are unwrapped at sync time" states the type-4-only
  rule, the typed errors and the `.error` log level (was `.fault`).
- `vault-item-edit-roundtrip`: the scenario "Item with a name in an old encryption format" (listed,
  readable, Edit disabled) no longer holds: such an item fails to decrypt and is excluded. It is
  removed by hand in the archive commit (OpenSpec refuses a MODIFIED block that drops a scenario of a
  long requirement). "Stored name without integrity protection" stays: it still guards a cached item
  whose stored record changed to type 0.

## Non-Goals

- Type 7 (COSE, v2 accounts) and legacy 32-byte user keys (C-08, C-09). Legacy accounts are refused
  with a named message in `account-scope-and-unsupported-features`, as official clients do.
- Decrypting org keys of types 3, 5 or 6. Prizm can't today, and no current writer was found.
- The attachment file layout (C-01): `fix-attachment-file-format`, which already refuses blob type 0
  and checks the MAC before AES for both layouts (`AttachmentBlobLayout`). Blob layouts are not
  touched here.
- Keeping unknown EncStrings as opaque values on edit (the SDK's `Unparseable`). Prizm keeps
  failing closed for such items.
- Replacing the DER parser with a library. No vetted Apple API imports PKCS#8 RSA keys directly
  (design.md D5).

## Dependencies

None. **Soft:**
- `fix-sync-decoding-resilience` shows items that fail here as placeholders and reports
  unavailable organizations. Without it they are excluded and logged, as today.
- `account-scope-and-unsupported-features` turns a type-0 user key (legacy account) into a named
  error. `decryptSymmetricKey` keeps a single place where the user key's type is checked, so that
  change can detect it. No type-0 decryption path is planned: official clients refuse legacy
  accounts ("legacyEncryptionUnsupported", `clients/libs/auth/src/angular/login/login.component.ts:424-432`).

## Impact

- **Data:**
  - `Data/Crypto/EncString.swift`: type table, parser, decrypt; the AES helpers become `internal`
  - `Data/Crypto/AttachmentCrypto.swift`: its private AES pair calls the `EncString` helpers (D3)
  - `Data/Crypto/PrizmCryptoService.swift`: `decryptSymmetricKey` (new type check),
    `decryptRSAPrivateKey`, `unwrapOrgKey` (strict type 4, typed error for 3/5/6),
    `stripPKCS8Header`, HKDF comment, two new error cases
  - `Data/Mappers/CipherMapper.swift`: comments of the type-2 guards and of `usesLegacyEncryption`
  - `Data/Repositories/SyncRepositoryImpl.swift`: org-key failure log level and text
  - Tests: `EncStringTests`, `OrgKeyCryptoKATTests`, `AttachmentCryptoTests` (the NIST AES test
    uses type 0 today and must call the AES helper directly), `EffectiveKeyReadTests` (type-0 item
    key), `FailClosedSaveTests.testStoredNameWithoutMAC_failsTheKeyCheck` (plaintext assertion),
    and the tests of the type-0 read-only display
- **Domain:** `EditBlockReason.legacyEncryption` doc comment (now only the save-time stored-record
  check). **Presentation:** none.
- **Docs:** SECURITY.md (EncString types accepted, HKDF row), CHANGELOG.
- **No new dependencies.**
- **Security review: yes** (§III: decryption, key unwrap, parser).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Failing tests for the bypass and the parser | 0.5 d |
| 2 | Type table, strict parser, type-2-only decrypt | 0.5–1 d |
| 3 | Org key: strict type-4 parse, typed error for types 3/5/6 | 0.25 d |
| 4 | DER bounds checks, fuzz-style tests | 0.5 d |
| 5 | HKDF KAT and docs, security review, CHANGELOG | 0.5 d |
| **Total** | | **2.25–2.75 d** |
