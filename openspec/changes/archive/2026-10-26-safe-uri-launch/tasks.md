# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Policy (0.5 d)

- [x] 1.1 Failing table test for `URILaunchPolicy.launchURL(for:)`: each of the 12 allowed prefixes (mixed case); `file:`, `smb:`, `javascript:`, `data:`, `x-custom://` → nil; `example.com/login` → `http://example.com/login`; `localhost:8080` → `http://localhost:8080`; `192.0.2.1/admin` → `http://192.0.2.1/admin`; `nas` → nil; empty and whitespace → nil; regular-expression match type → nil.
- [x] 1.2 Implement D1–D3 in `Domain/Utilities/URILaunchPolicy.swift` with the allow-list in an `enum` and a source comment (`safe-urls.ts`, `login-uri.view.ts`).

## 2. Wiring (0.5–1 d)

- [x] 2.1 `LoginDetailView` passes `URILaunchPolicy.launchURL(for:)` instead of `URL(string:)`.
- [x] 2.2 Failing test (view-model or snapshot): a URL whose scheme has no handler produces no button (D4). Implement the `NSWorkspace.urlForApplication(toOpen:)` check in Presentation.
- [x] 2.3 XCUITest with a fixture item: `file:` row has no open button; `example.com` row has one; VoiceOver label and hint unchanged.

## 3. Release (0.25 d)

- [x] 3.1 Security review: allow-list matches the official source; no other launch path builds URLs from stored URIs (grep `URL(string:` in Presentation).
  Done; see Results.
- [x] 3.2 CHANGELOG "Fixed": "Open in browser" now opens only web and other safe link types, as in official Bitwarden apps, and works for addresses saved without `http://`.
- [x] 3.3 `openspec validate safe-uri-launch --type change --strict`.
- [ ] 3.4 By hand, with VoiceOver or the Accessibility Inspector (XCUITest cannot read hints on macOS): the open button reads "Open Website" with the hint "Opens in browser"; the website value keeps "Copies Website to clipboard".
  Checked by hand 2026-10-29: the open button reads "Open Website" with the hint "Opens in browser". Still open: on the website value VoiceOver read `https://webauthn.io` while the screen showed `https://keyless.example.com`; the hint of the value was not reported. It happened right after viewing the passkey login (first URI `https://webauthn.io/`) and then selecting the other item. Looks like the stale-value bug that `fix-ui-journey-findings` worked around for selectable texts, now seen on the Websites rows (follow-up, not a regression of this change).

## Results (2026-10-26)

- Verified against `clients/libs/common/src/platform/misc/safe-urls.ts` (the 12 prefixes) and
  `login-uri.view.ts` (`canLaunch`, `launchUri`): `http://` is added only when that yields a
  domain, otherwise the URI is checked as is, so `ms-rd:` links keep working.
- `URILaunchPolicyTests` (table test, handler check with an injected closure). `URILaunchTarget` in
  Presentation adds the `NSWorkspace` handler check (D4) after the Domain policy.
- 2.3: `VaultBrowserJourneyTests.testOpenInBrowser_onlyForAllowedSchemes`; the Gamma fixture got
  a `file:` and a scheme-less website (not Kappa: more rows there would push its attachment section
  below the fold of the attachment UI tests). Found by label among links and buttons: the row's
  identifier overrides the button's. The hint "Opens in browser" is not checked: the row's own
  hint probably overrides it (pre-existing, open).
- 3.1: no other launch path; the other `URL(string:)` calls on stored URIs only read the host for
  favicons.
- The policy's table test (all `URILaunchPolicyTests` expectations plus an `ms-rd:` link with `@`,
  which opens as http like the official clients) was run in the Linux container against
  swift-foundation's URL parser, the same parser macOS 15+ uses: all pass.
- 3.1 security review: the allow-list matches `safe-urls.ts`; no disallowed scheme can pass; no
  other launch path. Fixed after review: the test class needed `@MainActor`; fixture moved.
  Not done: caching the per-scheme handler lookup (cheap LaunchServices query per row render).
- **Verified on the Mac (2026-10-26):** all 674 unit tests pass on this branch; the full UI suite passes on the top of the series (`fix/017`). The ms-rd test checks the decision, not the URL string, which macOS Foundation re-encodes.

## Verification (2026-10-26, `/opsx:verify`)

- **Divergence found and fixed:** the row set its copy hint on the whole row, and SwiftUI passes a
  container's accessibility modifiers to its children (as with the row identifier), so the open
  button probably read "Copies Website to clipboard" instead of "Opens in browser". The copy hint is
  now on the value elements only (`FieldRowView.copyHint`). Task 2.3's "hint unchanged" was not
  checked by the UI test, which cannot read hints; new hand check 3.4.
- Open for the maintainer: design Open Question 1 (`http://` as in the TypeScript clients, or
  `https://` as in iOS, for addresses without a scheme).

