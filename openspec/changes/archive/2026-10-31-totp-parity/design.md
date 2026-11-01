# Design

## Context

**Official parsing and generation.** SDK `crates/bitwarden-vault/src/totp.rs` at sdk-internal `c1c9b9a5`
(the TS clients call it: `clients/libs/common/src/vault/services/totp.service.ts:31-36`).
- Constants: base32 alphabet, Steam alphabet `23456789BCDFGHJKMNPQRTVWXY`, defaults SHA-1, 6
  digits, 30 s (`:23-28`).
- `FromStr` (`:181-256`): the whole key is lowercased first.
  - `otpauth://`: parsed with `Url::parse`; the type (`totp`/`hotp`) is **not** checked;
    `algorithm` sha1/sha256/sha512, anything else → SHA-1; `digits` parsed as `u32`, clamped to
    0–10, unparsable → 6; `period` parsed as `u32`, `max(1)`, unparsable → 30; missing `secret` →
    `MissingSecret`.
  - `steam://<secret>`: algorithm Steam, 5 digits, 30 s.
  - Otherwise: the whole string is the secret.
- `decode_b32` (`:350-368`): uppercases, keeps only base32 characters, drops trailing partial bits.
  An empty result is not an error.
- `derive_otp` (`:163-177`): RFC 6238 counter, RFC 4226 truncation (`derive_binary`, `:339-346`);
  Steam → `derive_steam_otp`, otherwise `binary % 10_u32.pow(digits)`, zero-padded.
- `derive_steam_otp` (`:322-336`): `full = binary & 0x7fffffff`; repeat 5 times: append
  `STEAM_CHARS[full % 26]`, `full /= 26`. Steam uses HMAC-SHA1 (`:126-129`).
- **10 digits:** `10_u32.pow(10)` exceeds `u32`. The SDK's release profile
  (`Cargo.toml:231-234`) doesn't enable overflow checks, so the multiplication wraps to
  1 410 065 408. For 10 digits the official code then differs from RFC 4226 arithmetic whenever the
  truncated value is at least 1 410 065 408 (about a third of the time). This is read from source,
  not tested (task 1.2).
- Display grouping: codes longer than 4 characters are split at `floor(len/2)`
  (`clients/libs/vault/src/components/totp-countdown/totp-countdown.component.ts:77-83`). Steam:
  "AB CDE".

**Official gating.**
- Copy: `organizationUseTotp || hasPremiumFromAnySource`
  (`clients/libs/vault/src/services/copy-cipher-field.service.ts:215-231`).
- Web/desktop item view: code masked, countdown hidden, copy disabled unless
  `hasPremiumFromAnySource` (`libs/vault/src/cipher-view/login-credentials/login-credentials-view.component.html:141-180`,
  `.ts:87-95`). This view does not consider `organizationUseTotp`.
- iOS: copy TOTP offered when `hasPremium || organizationUseTotp`
  (`ios/BitwardenShared/UI/Vault/Utilities/CipherMoreOptions.swift:272-274`).
- Server data: profile `premium` and `premiumFromOrganization`
  (`server/src/Api/Models/Response/ProfileResponseModel.cs:64-65`); cipher `organizationUseTotp`.
  Vaultwarden 1.37.4 always sends `"premium": true` (`src/db/models/user.rs:312-313`) and
  `"organizationUseTotp": true` (`src/db/models/cipher.rs:341`).

**Prizm today.**
- `Domain/Utilities/TOTPSeedParser.swift`: rejects `://` other than `otpauth` (`:24-25`), non-`totp`
  host (`:46`), unknown algorithm (`:60`), digits outside 6–8 (`:39, 64`), non-numeric or `period ≤ 0`
  (`:66-67, 72-76`), any non-base32 character (`:94`), empty secret (`:103`).
- `Data/UseCases/GenerateTOTPCodeUseCaseImpl.swift:51-62`: `UInt64` modulus, decimal only.
- `RawProfile` (`Data/Network/Models/SyncResponse.swift:144`) has no premium fields; `RawCipher` has
  no `organizationUseTotp`.
- The feature is unreleased (`CHANGELOG.md`, "Unreleased").

## Goals / Non-Goals

**Goals**
- A seed that shows a code in official apps shows the same code in Prizm, except for the two
  recorded differences (D2) and possibly 10-digit codes (D3).
- Prizm shows codes to the same accounts as official apps.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Lenient parsing, as the SDK

- The seed is trimmed of leading and trailing whitespace (D2), then lowercased as a whole, as the SDK.
- Prefix: `otpauth://` (any case) → URI; `steam://` → Steam; **any other string, including other
  schemes such as `https://…`, is a plain secret.**
- `otpauth://` host: `hotp` → "unavailable" (D2); any other host, including an empty one, → TOTP.
  The host is read as WHATWG does: without `userinfo@` and `:port` (`otpauth://u@hotp/…`,
  `otpauth://hotp:1/…` are counter-based too).
- URI parsing follows the SDK's WHATWG `Url::parse` + form-urlencoded `query_pairs`, not
  `URLComponents(string:)`: unencoded spaces in the label are accepted (`ACME Co:me`), `+` in a
  query value is a space, each valid percent escape is decoded byte by byte and an invalid one kept
  as written, the bytes are read as UTF-8 with U+FFFD for invalid sequences, and for a key given twice the **last** value
  wins (`HashMap`, `totp.rs:201`). Prizm splits the query itself instead of relying on
  `URLComponents`, which returns nil for a raw space and keeps the first duplicate.
- Missing `secret` → "unavailable" (SDK `MissingSecret`, `:232`).
- Secrets: filter the `unicodeScalars` of `lowercased().uppercased()` (the SDK iterates scalars, not
  grapheme clusters), keep only `A–Z2–7`; spaces, dashes, `=` and other characters are dropped.
  Decoding takes exact 8-bit chunks and drops leftover bits.
- `algorithm`: `sha1`/`sha256`/`sha512` (case-insensitive, also after decoding: `%53HA256` is
  SHA-256), anything else → SHA-1.
- `digits` and `period`: an unsigned 32-bit decimal (optional leading `+`, as Rust's `u32::from_str`)
  else the default (6 / 30); negative values and values above 4 294 967 295 are parse failures, not
  clamped. Then `digits` is clamped to 0…10 (0 → "unavailable", D2) and `period` to at least 1.
- `steam://<secret>`: Steam, 5 characters, 30 s.

**Why the earlier "reject" decision changes.** `research.md:17-18` wanted to avoid wrong codes.
But an item is shared with official apps: if the browser extension shows a code and Prizm shows
"unavailable", users trust Prizm less, not more. Matching the SDK gives the code the user sees
everywhere else.

### D2. Two recorded differences from the SDK

| Input | SDK | Prizm | Why |
|---|---|---|---|
| `otpauth://hotp/…` | treated as TOTP | "unavailable" | A time-based code for a counter-based seed is always wrong. |
| secret that decodes to zero bytes (fewer than 8 bits of base32, e.g. `A`, `steam://`, `!!!`), or `digits=0` | computes a code from an empty key / a 1-character "0" | "unavailable" | The result can never be a valid code. |
| leading or trailing whitespace around the seed | not trimmed: ` otpauth://…` becomes a plain secret built from the URI's letters | trimmed, then parsed | A pasted seed with a stray space is meant as the URI; the SDK's result is never the intended code. |

### D3. 9 and 10 digits use RFC arithmetic

`GenerateTOTPCodeUseCaseImpl` already uses a 64-bit modulus, which is correct per RFC 4226 for 9
and 10 digits. The SDK computes `binary % 10_u32.pow(digits)` (`totp.rs:174`, sdk-internal
`c1c9b9a5`): for 10 digits `10^10` overflows `u32`, so a release build divides by
`10^10 mod 2^32 = 1 410 065 408` and shows a different code whenever the truncated value is at least
that (debug builds panic). Prizm keeps RFC arithmetic: the website that verifies the code follows
the RFC. Recorded in `research.md` (task 6.1). A known-answer test pins a 10-digit case whose
truncated value is at least 1 410 065 408 to the RFC result (task 3.1); the rig check excludes
10-digit seeds, because `bw` shows the wrapped code.

### D4. Steam derivation

`TOTPConfiguration` gets `alphabet: .decimal | .steam`. For `.steam`: HMAC-SHA1, truncate as RFC
4226, mask `0x7fffffff`, then 5 base-26 digits from the Steam alphabet, least significant first (as
`derive_steam_otp`). Known-answer tests use the SDK's own vectors (`totp.rs` `test_generate_totp`,
sdk-internal `c1c9b9a5`, time 2023-01-01T00:00:00Z): `steam://HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ`
→ `7W6CJ` (also with the prefix in mixed case), `steam://ABCD123` → `N26DF`; and for plain seeds
`WQIQ25BRKZYCJVYP` → `194506` (also lowercase), `PIUDISEQYA` → `829846` (also padded and as
`PIUD1IS!EQYA=`), `ddfdf` → `932653`, `HJSGFJHDFDJDJKSDFD` → `000034`,
`xvdsfasdfasdasdghsgsdfg` → `403786`, `KAKFJWOSFJ12NWL` → `093430`; and for URIs
(`totp.rs:424-487`) `OTPauth://totp/…` → `194506`, `period=60` → `730364`,
`algorithm=SHA256` → `842615`; `decode_b32("ABCD123")` = `[0, 68, 61]` (`:386-387`). The SDK lowercases the whole
key first and decodes base32 in exact 8-bit chunks, dropping leftover bits (`decode_b32`).

### D4a. Display grouping

`TOTPCode.grouped` splits only codes longer than 4 characters, at `floor(len/2)`, as the official
countdown component: 1–4 digits are shown unsplit, 10 digits as "12345 67890", Steam as "7W 6CJ".
The copied value is the raw code without spaces (Steam copies "7W6CJ"). VoiceOver reads Steam
characters one by one through the existing `spokenDigits` ("7 W 6 C J").

### D5. No entitlement gate

Decided with Christian (2026-10-30): Prizm gates a feature only where the server enforces it.
Codes are computed on the device from the user's own seed; no server takes part, so there is
nothing to react to. Prizm shows and copies codes for every item with a usable seed, whatever
`premium`, `premiumFromOrganization` or `organizationUseTotp` say, and decodes none of them.

**Rejected alternative:** the official apps' copy rule (`hasPremium || organizationUseTotp`). It
enforces nothing on the server and would only copy another client's licensing decision.

## Risks / Trade-offs

- **[Low] A malformed seed now shows a code** where it used to show "unavailable". → The code is
  the same one official apps show for that item.
- **[Low] Users without premium on Bitwarden's own servers see codes in Prizm** that the official
  apps hide from them. No server enforces it (D5); accepted.

## Open Questions

None. Closed 2026-10-30: the SDK wraps for 10 digits, Prizm keeps RFC arithmetic (D3, from source);
no entitlement gate (Christian, D5).

## Review

- Spec challenge (fresh agent, before code): 14 findings, all adopted; trimming surrounding
  whitespace kept as a recorded difference (D2).
- Code review (fresh agent, 2026-10-31): 0 high/medium, 4 low, all fixed (percent escapes decoded
  one at a time as WHATWG does, algorithm lowercased after decoding, host without userinfo or
  port, more tests incl. the entitlement source scan of task 4.1; red 20261031T080821Z, green
  20261031T080903Z).
- Security review: the seed is never logged or put in an error (Constitution §III, §V); parsing is
  an encoding, not cryptography; HMAC stays behind `PrizmCryptoService`.
- `/opsx:verify` (2026-10-31): 0 critical, 0 warnings, 2 suggestions, done (Steam copy test, comment;
  green 20261031T182647Z).
- Rig (Vaultwarden 1.37.4, `bw` 2026.9.1): plain, `otpauth` SHA-256/8/60 and `steam://` seeds give
  the same codes as `bw get totp` (20261031T081759Z).
- UI: `VerificationCodeJourneyTests` passed in the final batch run 20261031T210247Z. VoiceOver
  hand check of a Steam row: Christian, 2026-10-31.
