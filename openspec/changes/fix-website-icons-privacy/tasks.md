# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 0. Checkpoint

- [x] 0.1 Spec challenge by a fresh agent (Lane B), 2026-10-30, against the code at develop `ce678163`. Done: 18 findings, all adopted into proposal, design (D1–D5) and specs; the redirect question went to Christian, who chose D5 (refuse by default, setting "Allow icons from other services").

## 1. Server icons URL (1 d)

- [ ] 1.1 Failing test with a URL protocol stub that fails on any host but the configured one: `FaviconLoader` configured with `https://vault.example.com/icons` requests `…/icons/github.com/icon.png` without `Authorization`, `Bitwarden-Client-*` or cookie headers; unconfigured or `nil` sends nothing; no request ever goes to `icons.bitwarden.net`.
- [ ] 1.2 Remove the default URL; add `configure(iconsBase:)` and `reset()`. Update the doc comment (source of the URL, Constitution "Server URL" rule).
- [ ] 1.3 Add `faviconLoader` to `RootViewModelDependencies` (like `attachmentTempFiles`); configure in `transitionToVault` (`nil` in UI-test mode); `nil` + `reset()` in `lockVault` and `signOut`. Tests in `RootViewModelLockTests`.
- [ ] 1.4 Rig (Vaultwarden 1.37.4 behind the edge): Prizm's real `FaviconLoader` configured with the rig's `/icons` loads an icon; unconfigured and after `configure(nil)` + `reset()` it returns none without a request. Record the result in design.md, Context. Documented gaps (decided with Christian 2026-10-30, covered by unit tests through `URLSession`'s redirect handling and the non-200 path): the edge access log, `DISABLE_ICON_DOWNLOAD=true` and `ICON_SERVICE=bitwarden` (need server settings changed on the Mac); Bitwarden self-hosted not available.

## 2. Host rules (1 d)

- [ ] 2.1 Failing table test for `WebsiteIconHost.host(for:)` with the cases from the spec, plus upper-case schemes, trailing dots, empty and whitespace strings.
- [ ] 2.2 Implement D3 in `Domain/Utilities/WebsiteIconHost.swift` (Foundation only).
- [ ] 2.3 Replace the three `primaryDomain(for:)` helpers (`ItemRowView`, `ItemDetailView`, `VerificationCodesListView`) with the utility on `firstAddress`; `TrashView` follows through `ItemRowView`.

## 3. Settings (0.75–1.25 d)

- [ ] 3.1 Failing tests: `WebsiteIconSettings` defaults (icons on, other services off) and keys; the loader with icons off returns `nil`, sends nothing and empties its cache; with icons on again it loads.
- [ ] 3.2 "Privacy" section in `SettingsView` below "Security": the two toggles with `@AppStorage`, help texts as `.help` (D2); "Allow icons from other services" disabled while icons are off. Accessibility identifiers. No new DesignSystem tokens needed.
- [ ] 3.3 `FaviconView` follows "Show website icons" (D2): reloads on domain and setting, clears its image when off. Test the view's load decision at unit level (`FaviconView` is hidden from VoiceOver, and UI-test mode loads no icons).
- [ ] 3.4 XCUITest: the Settings window shows both toggles with their labels; "Allow icons from other services" is disabled while icons are off; values persist after reopening Settings.
- [ ] 3.5 VoiceOver hand check: both toggles are read with label, state and help.

## 4. Cache and redirects (0.75 d)

- [ ] 4.1 Failing tests: the loader's session configuration has `urlCache == nil` and no cookie storage; `reset()` empties the in-memory cache; a `reset()` while a stubbed request is suspended leaves the cache empty after it finishes.
- [ ] 4.2 Implement D4 (ephemeral session, generation counter, task cancellation). `URLCache.shared.removeAllCachedResponses()` once per launch.
- [ ] 4.3 Failing tests (stub): a 302 to another host with "Allow icons from other services" off sends no request to that host and returns `nil`; with it on, the target is requested and its image returned; a redirect to another path on the same origin is followed either way.
- [ ] 4.4 Implement D5 in the session delegate.

## 5. Docs and release (0.5 d)

- [ ] 5.1 README "Privacy & Security": icons come from your server's icon service, which may contact the websites; can be turned off in Settings; "Allow icons from other services" lets the server's redirect to an outside icon service through.
- [ ] 5.2 SECURITY.md network section: icon requests, what they reveal to the server (and to an outside service when allowed), the two settings, no disk cache.
- [ ] 5.3 Privacy/security review (`/security-review`): every icon request path goes through the configured base and the redirect check; no request to third-party hosts. Hand check on the Mac with `nettop -P -p Prizm` while scrolling the list, icons on and off, other services off: only the rig's host appears.
- [ ] 5.4 CHANGELOG "Fixed": website icons are loaded from your own server instead of Bitwarden's icon service. "Added": settings to turn website icons off and to allow icons from other services.
- [ ] 5.5 `/code-review`, `openspec validate fix-website-icons-privacy --type change --strict`, `/opsx:verify`.
- [ ] 5.6 Archive the change (at the end of the batch, in PR order).
