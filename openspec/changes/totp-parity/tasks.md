# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Vectors and confirmation (0.5 d)

- [ ] 1.1 Commit the SDK's own vectors (design D4, `totp.rs:393-406,424-487` at sdk-internal `c1c9b9a5`, including the URI vectors and `decode_b32("ABCD123")`) as a fixture with the commit hash; parsing cases without SDK codes (`algorithm=MD5` → SHA-1, `digits=5`/`9`, `period=abc` → 30, `digits=-1` → 6, `period=-30` → 30, `digits=99999999999` → 6) are asserted on the parsed configuration.
- [x] 1.2 SDK 10-digit arithmetic: wraps to `% 1 410 065 408` in release (`totp.rs:174`, from source); Prizm keeps RFC (design D3).

## 2. Lenient parsing (1 d)

- [ ] 2.0 Repoint fixtures and tests that relied on rejection: UI fixture `delta` (`UITestFixtures.swift:265`, `not-a-seed!` now gives a code) → `secret=!!!` or `otpauth://hotp/…`; invert `VerificationCodeJourneyTests.swift:93-98`, `RootViewModelCopyCodeTests.swift:78-82` (`not-a-seed!`, `steam://`), `TOTPSeedParserTests.swift:65-90` (steam, MD5, digits 5/9, `period=-30`, `abc`).
- [ ] 2.1 Failing table tests for `TOTPSeedParser`: the D1 rules (prefix and host rules incl. empty host and `https://…` as plain secret, raw-space label, `+` and percent escapes, `secret=` given twice → last wins, unsigned-integer rule, scalar filtering of `İ` and a combining accent, trimming) and the D2 exceptions (hotp, zero-byte secret: `A`, `steam://`, `!!!`; `digits=0`; missing `secret`).
- [ ] 2.2 Implement D1 and D2. Keep the "seed never logged or put in an error" rule (§III, §V).

## 3. Steam (0.5–1 d)

- [ ] 3.1 Failing known-answer tests against the SDK vectors from 1.1, plus a 10-digit RFC case whose truncated value is ≥ 1 410 065 408 (design D3).
- [ ] 3.2 Implement D4 in `TOTPConfiguration` and `GenerateTOTPCodeUseCaseImpl`. `TOTPCode.grouped` groups only above 4 characters (design D4a). Tests: `digits=1` unsplit, `digits=4` unsplit, `digits=10` "12345 67890", Steam "7W 6CJ"; a Steam copy is "7W6CJ".

## 4. No gating (0.1 d)

- [ ] 4.1 Test: a login with a seed shows and copies a code whatever the profile's premium fields say (design D5). Check that no entitlement field is decoded: `grep -nE 'premium|organizationUseTotp' Prizm/Data/Network/Models/SyncResponse.swift` finds nothing (result in this task).

## 5. Release (0.5 d)

- [ ] 5.1 Interop check on the rig: items with the 1.1 seeds (no 10-digit seeds: `bw` shows the wrapped code, design D3), read back with the official `bw` CLI (`bw get totp`) at the same time, show the same codes as Prizm.
- [ ] 5.5 Approved UI run: `VerificationCodeJourneyTests` (fixture changes of 2.0).
- [ ] 5.6 VoiceOver hand check of a Steam code row (§VIII).
- [ ] 5.2 CHANGELOG (extend the "Unreleased" verification-codes entry): Steam codes; seeds accepted like official apps.
- [ ] 5.3 README: list supported seed forms and the two exceptions (HOTP, empty secret).
- [ ] 5.4 `openspec validate totp-parity --type change --strict`.

## 6. Spec corrections (in 5's estimate)

- [ ] 6.1 `specs/001-totp-verification-codes/research.md:14-18`: correct "Covers what authenticator apps and Bitwarden accept" and the rejected-inputs list; reference this change.
- [ ] 6.2 `specs/001-totp-verification-codes/spec.md` FR-005 (`:95`, grouping), FR-008 (`:98`) and the Steam assumption (`:131`).
- [ ] 6.3 `specs/001-totp-verification-codes/data-model.md:17,34,47` and `contracts/domain-protocols.md`; code comments `TOTPSeedParser.swift:5-11` ("rejected rather than coerced") and `TOTPConfiguration.swift:27-29,43`.
