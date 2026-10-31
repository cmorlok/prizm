# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Vectors and confirmation (0.5 d)

- [x] 1.1 Commit the SDK's own vectors (design D4, `totp.rs:393-406,424-487` at sdk-internal `c1c9b9a5`, including the URI vectors and `decode_b32("ABCD123")`) as a fixture with the commit hash; parsing cases without SDK codes (`algorithm=MD5` → SHA-1, `digits=5`/`9`, `period=abc` → 30, `digits=-1` → 6, `period=-30` → 30, `digits=99999999999` → 6) are asserted on the parsed configuration. Done: the vectors live in `TOTPKnownAnswerTests` (with the commit hash, incl. `steam://`, `StEam://` and `steam://ABCD123` → N26DF) rather than a JSON file; the parsing cases in `TOTPSeedParserTests`.
- [x] 1.2 SDK 10-digit arithmetic: wraps to `% 1 410 065 408` in release (`totp.rs:174`, from source); Prizm keeps RFC (design D3).

## 2. Lenient parsing (1 d)

- [x] 2.0 Repoint fixtures and tests that relied on rejection: UI fixture `delta` (`UITestFixtures.swift:265`, `not-a-seed!` now gives a code) → `secret=!!!` or `otpauth://hotp/…`; invert `VerificationCodeJourneyTests.swift:93-98`, `RootViewModelCopyCodeTests.swift:78-82` (`not-a-seed!`, `steam://`), `TOTPSeedParserTests.swift:65-90` (steam, MD5, digits 5/9, `period=-30`, `abc`). Done: `delta` is now an `otpauth://hotp` link, so it stays "unavailable" and `VerificationCodeJourneyTests` needed no change; the unit tests are inverted.
- [x] 2.1 Failing table tests for `TOTPSeedParser`: the D1 rules (prefix and host rules incl. empty host and `https://…` as plain secret, raw-space label, `+` and percent escapes, `secret=` given twice → last wins, unsigned-integer rule, scalar filtering of `İ` and a combining accent, trimming) and the D2 exceptions (hotp, zero-byte secret: `A`, `steam://`, `!!!`; `digits=0`; missing `secret`). Done: `TOTPSeedParserTests`; red 20261030T202834Z. Code review R1-R4 (per-escape decoding as WHATWG, algorithm lowercased after decoding, host without userinfo/port, more cases): red 20261031T080821Z, green 20261031T080903Z (1382).
- [x] 2.2 Implement D1 and D2. Keep the "seed never logged or put in an error" rule (§III, §V). Done; green 20261030T202946Z (1378). `digits=+8` gives 6, as in the SDK (form decoding turns `+` into a space).

## 3. Steam (0.5–1 d)

- [x] 3.1 Failing known-answer tests against the SDK vectors from 1.1, plus a 10-digit RFC case whose truncated value is ≥ 1 410 065 408 (design D3). Done: `TOTPKnownAnswerTests`.
- [x] 3.2 Implement D4 in `TOTPConfiguration` and `GenerateTOTPCodeUseCaseImpl`. `TOTPCode.grouped` groups only above 4 characters (design D4a). Tests: `digits=1` unsplit, `digits=4` unsplit, `digits=10` "12345 67890", Steam "7W 6CJ"; a Steam copy is "7W6CJ". Done: `TOTPCodeTests`; the Steam copy test `test_copyCode_steam_copiesTheFiveCharacters` was added at verification (green 20261031T182647Z, 1384).

## 4. No gating (0.1 d)

- [x] 4.1 Test: a login with a seed shows and copies a code whatever the profile's premium fields say (design D5). Check that no entitlement field is decoded: `grep -nE 'premium|organizationUseTotp' Prizm/Data/Network/Models/SyncResponse.swift` finds nothing (result in this task). Done: no gate exists to test against, so the check is the source scan (code review R4): the grep finds nothing (re-run 2026-10-31 on fix/039).

## 5. Release (0.5 d)

- [x] 5.1 Interop check on the rig: items with the 1.1 seeds (no 10-digit seeds: `bw` shows the wrapped code, design D3), read back with the official `bw` CLI (`bw get totp`) at the same time, show the same codes as Prizm. Done: batch-3 rig run 20261031T081759Z, all PASS (plain secret, `otpauth` SHA-256/8 digits/60 s, `steam://`: Prizm's codes equal `bw get totp`, bw 2026.9.1).
- [x] 5.5 Approved UI run: `VerificationCodeJourneyTests` (fixture changes of 2.0). Done: full UI suite 20261030T205732Z and the final batch UI run.
- [x] 5.6 VoiceOver hand check of a Steam code row (§VIII). Done: Christian, 2026-10-31 (Debug build of the batch-3 integration branch): Steam code row confirmed.
- [x] 5.2 CHANGELOG (extend the "Unreleased" verification-codes entry): Steam codes; seeds accepted like official apps. Done.
- [x] 5.3 README: list supported seed forms and the two exceptions (HOTP, empty secret). Done (docs commit; README feature line and SECURITY.md "Verification Codes").
- [x] 5.4 `openspec validate totp-parity --type change --strict`. Done before the archive.

## 6. Spec corrections (in 5's estimate)

- [x] 6.1 `specs/001-totp-verification-codes/research.md:14-18`: correct "Covers what authenticator apps and Bitwarden accept" and the rejected-inputs list; reference this change. Done (docs commit).
- [x] 6.2 `specs/001-totp-verification-codes/spec.md` FR-005 (`:95`, grouping), FR-008 (`:98`) and the Steam assumption (`:131`). Done (docs commit).
- [x] 6.3 `specs/001-totp-verification-codes/data-model.md:17,34,47` and `contracts/domain-protocols.md`; code comments `TOTPSeedParser.swift:5-11` ("rejected rather than coerced") and `TOTPConfiguration.swift:27-29,43`. Done: the Spec Kit files in the docs commit; the code comments in the code commit.
