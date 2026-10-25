# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Policy (0.5 d)

- [ ] 1.1 Failing table test for `URILaunchPolicy.launchURL(for:)`: each of the 12 allowed prefixes (mixed case); `file:`, `smb:`, `javascript:`, `data:`, `x-custom://` → nil; `example.com/login` → `http://example.com/login`; `localhost:8080` → `http://localhost:8080`; `192.0.2.1/admin` → `http://192.0.2.1/admin`; `nas` → nil; empty and whitespace → nil; regular-expression match type → nil.
- [ ] 1.2 Implement D1–D3 in `Domain/Utilities/URILaunchPolicy.swift` with the allow-list in an `enum` and a source comment (`safe-urls.ts`, `login-uri.view.ts`).

## 2. Wiring (0.5–1 d)

- [ ] 2.1 `LoginDetailView` passes `URILaunchPolicy.launchURL(for:)` instead of `URL(string:)`.
- [ ] 2.2 Failing test (view-model or snapshot): a URL whose scheme has no handler produces no button (D4). Implement the `NSWorkspace.urlForApplication(toOpen:)` check in Presentation.
- [ ] 2.3 XCUITest with a fixture item: `file:` row has no open button; `example.com` row has one; VoiceOver label and hint unchanged.

## 3. Release (0.25 d)

- [ ] 3.1 Security review: allow-list matches the official source; no other launch path builds URLs from stored URIs (grep `URL(string:` in Presentation).
- [ ] 3.2 CHANGELOG "Fixed": "Open in browser" now opens only web and other safe link types, as in official Bitwarden apps, and works for addresses saved without `http://`.
- [ ] 3.3 `openspec validate safe-uri-launch --type change --strict`.
