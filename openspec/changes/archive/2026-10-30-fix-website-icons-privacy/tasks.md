# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 0. Checkpoint

- [x] 0.1 Spec challenge by a fresh agent (Lane B), 2026-10-30, against the code at develop `ce678163`. Done: 18 findings, all adopted into proposal, design (D1–D5) and specs; the redirect question went to Christian, who chose D5 (refuse by default, setting "Allow icons from other services").

## 1. Server icons URL (1 d)

- [x] 1.1 Failing test with a URL protocol stub that fails on any host but the configured one: `FaviconLoader` configured with `https://vault.example.com/icons` requests `…/icons/github.com/icon.png` without `Authorization`, `Bitwarden-Client-*` or cookie headers; unconfigured or `nil` sends nothing; no request ever goes to `icons.bitwarden.net`. Done: `FaviconLoaderTests` (`IconStub` fails any unexpected host) and `ClientIdentificationHeaderTests`; red 20261030T163903Z.
- [x] 1.2 Remove the default URL; add `configure(iconsBase:)` and `reset()`. Update the doc comment (source of the URL, Constitution "Server URL" rule). Done; green 20261030T164057Z. `configure` is synchronous (Mutex) since the code review.
- [x] 1.3 Add `faviconLoader` to `RootViewModelDependencies` (like `attachmentTempFiles`); configure in `transitionToVault` (`nil` in UI-test mode); `nil` + `reset()` in `lockVault` and `signOut`. Tests in `RootViewModelLockTests`. Done: `RootViewModelLockTests` (red 20261030T164341Z, green 20261030T164414Z). Code review: configured before the vault shows and cleared as a lock or sign-out starts (`testVaultTransition_configuresTheAccountsIconService_beforeTheVaultShows`, `testLockVault_unconfiguresTheIconService_rightAway`; red 20261030T171128Z, green 20261030T171235Z).
- [x] 1.4 Rig (Vaultwarden 1.37.4 behind the edge): Prizm's real `FaviconLoader` configured with the rig's `/icons` loads an icon; unconfigured and after `configure(nil)` + `reset()` it returns none without a request. Record the result in design.md, Context. Documented gaps (decided with Christian 2026-10-30, covered by unit tests through `URLSession`'s redirect handling and the non-200 path): the edge access log, `DISABLE_ICON_DOWNLOAD=true` and `ICON_SERVICE=bitwarden` (need server settings changed on the Mac); Bitwarden self-hosted not available. Done: live run 20261030T165944Z, `030.1.4.icon` PASS (19×19 icon from `https://localhost:8443/icons`), `030.1.4.lock` PASS; result in design.md, Context.

## 2. Host rules (1 d)

- [x] 2.1 Failing table test for `WebsiteIconHost.host(for:)` with the cases from the spec, plus upper-case schemes, trailing dots, empty and whitespace strings. Done: `WebsiteIconHostTests`; red 20261030T163903Z. Security review: empty labels refused (red 20261030T170026Z, green 20261030T170050Z). Code review: trailing dot dropped.
- [x] 2.2 Implement D3 in `Domain/Utilities/WebsiteIconHost.swift` (Foundation only). Done.
- [x] 2.3 Replace the three `primaryDomain(for:)` helpers (`ItemRowView`, `ItemDetailView`, `VerificationCodesListView`) with the utility on `firstAddress`; `TrashView` follows through `ItemRowView`. Done; since the code review one shared `WebsiteIconHost.host(for: VaultItem)` (`testHostOfAnItem_isTheFirstLoginURIsHost`).

## 3. Settings (0.75–1.25 d)

- [x] 3.1 Failing tests: `WebsiteIconSettings` defaults (icons on, other services off) and keys; the loader with icons off returns `nil`, sends nothing and empties its cache; with icons on again it loads. Done: `FaviconLoaderTests.testSettingsDefaults`, `testIconsOff_sendsNothing_andEmptiesTheCache`; red 20261030T163903Z. Code review: the loader resets itself when icons are turned off (`testTurningIconsOff_resetsTheLoader`, `testRequestFinishingAfterIconsOff_isNotCached`).
- [x] 3.2 "Privacy" section in `SettingsView` below "Security": the two toggles with `@AppStorage`, help texts as `.help` (D2); "Allow icons from other services" disabled while icons are off. Accessibility identifiers. No new DesignSystem tokens needed. Done; both switches carry an explicit accessibility label (found by the UI run).
- [x] 3.3 `FaviconView` follows "Show website icons" (D2): reloads on domain and setting, clears its image when off. Test the view's load decision at unit level (`FaviconView` is hidden from VoiceOver, and UI-test mode loads no icons). Done: `FaviconViewTests`; red 20261030T164526Z, green 20261030T164557Z.
- [x] 3.4 XCUITest: the Settings window shows both toggles with their labels; "Allow icons from other services" is disabled while icons are off; values persist after reopening Settings. Done: `WebsiteIconSettingsTests`, approved UI run 20261030T175108Z, 1 test, 0 failures (after two fixes: teardown restore, accessibility labels).
- [x] 3.5 VoiceOver hand check: both toggles are read with label, state and help. Done: Christian, 2026-10-30, Debug build of the batch-2 integration branch: labels, state and help read; "Allow icons from other services" read as dimmed while icons are off.

## 4. Cache and redirects (0.75 d)

- [x] 4.1 Failing tests: the loader's session configuration has `urlCache == nil` and no cookie storage; `reset()` empties the in-memory cache; a `reset()` while a stubbed request is suspended leaves the cache empty after it finishes. Done: `testSessionConfiguration_hasNoDiskCacheAndNoCookies`, `testRepeatedRequest_comesFromTheMemoryCache`, `testResetDuringARequest_leavesTheCacheEmpty`; red 20261030T163903Z.
- [x] 4.2 Implement D4 (ephemeral session, generation counter, task cancellation). `URLCache.shared.removeAllCachedResponses()` once per launch. Done. Code review: one request per host (`testConcurrentRequestsForOneHost_sendOneRequest`); the per-launch cache clear is kept with its reason in design.md D4.
- [x] 4.3 Failing tests (stub): a 302 to another host with "Allow icons from other services" off sends no request to that host and returns `nil`; with it on, the target is requested and its image returned; a redirect to another path on the same origin is followed either way. Done: redirect tests in `FaviconLoaderTests`; red 20261030T163903Z. Code review: a plain-`http` target is refused even when allowed (`testRedirectToPlainHTTP_isRefusedEvenWhenAllowed`).
- [x] 4.4 Implement D5 in the session delegate. Done (completion-handler delegate; the async form crashes the Swift 6.2 compiler).

## 5. Docs and release (0.5 d)

- [x] 5.1 README "Privacy & Security": icons come from your server's icon service, which may contact the websites; can be turned off in Settings; "Allow icons from other services" lets the server's redirect to an outside icon service through. Done.
- [x] 5.2 SECURITY.md network section: icon requests, what they reveal to the server (and to an outside service when allowed), the two settings, no disk cache. Done.
- [x] 5.3 Privacy/security review (`/security-review`): every icon request path goes through the configured base and the redirect check; no request to third-party hosts. Hand check on the Mac with `nettop -P -p Prizm` while scrolling the list, icons on and off, other services off: only the rig's host appears. Done: `/security-review` 2026-10-30 (fresh agent): no findings, one LOW note fixed (hosts of dots only). Hand check (Christian, 2026-10-30): `nettop -n -p Prizm` after lock, unlock and scrolling showed only connections to `127.0.0.1:8443`; with icons off as expected.
- [x] 5.4 CHANGELOG "Fixed": website icons are loaded from your own server instead of Bitwarden's icon service. "Added": settings to turn website icons off and to allow icons from other services. Done (CHANGELOG, Unreleased).
- [x] 5.5 `/code-review`, `openspec validate fix-website-icons-privacy --type change --strict`, `/opsx:verify`. Done 2026-10-30: `/code-review` high, 10 findings, 9 fixed, 1 kept with its reason (design D4); `validate --strict` valid; `/opsx:verify`: 6/6 requirements, 12/12 scenarios covered; the scenario "First URI without a value" got a direct test (`testHostOfAnItem_skipsAURIWithoutAValue`, characterisation, green 20261030T181849Z); no critical issues or warnings.
- [x] 5.6 Archive the change (at the end of the batch, in PR order). Done 2026-10-30 (`openspec archive`).
