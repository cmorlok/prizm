# Design

## Context

**Rig result (task 1.4, 2026-10-30).** Vaultwarden 1.37.4 behind the edge, integration branch of
batch 2: the real `FaviconLoader` configured with `https://localhost:8443/icons` loaded a 19×19 icon
for `github.com`; unconfigured, and after `configure(nil)` + `reset()`, it returned none without a
request. Not run, by decision (covered by unit tests): the edge access log, `DISABLE_ICON_DOWNLOAD`
and `ICON_SERVICE=bitwarden`, which need server settings changed on the Mac.

**Official icon URL.** Sources at HEAD 2026-10-23.
- `clients/libs/common/src/platform/services/default-environment.service.ts:417-419`:
  `getIconsUrl()` returns the configured icons URL, otherwise `base + "/icons"`. The cloud icon hosts
  (`icons.bitwarden.net`, `.eu`, `-gov.com`) are only the defaults of the cloud regions (`:94, 109, 124`).
- iOS passes `EnvironmentService.iconsURL` (`ios/BitwardenShared/Core/Platform/Services/EnvironmentService.swift:142-143`) as the base (`UI/Vault/Vault/VaultCoordinator.swift:319`).

**Official URI rules.** `clients/libs/common/src/vault/icon/build-cipher-icon.ts:36-84`:
- No icons URL → icons off (`:36-38`).
- `androidapp://` and `iosapp://` → no image (`:52-59`).
- Scheme-less URI (no `://`) that contains a dot → prefix `http://`, treat as website (`:60-66`).
- Otherwise a website only if it starts with `http` and contains a dot (`:67-69`).
- `.onion` and `.i2p` → no image. The check is `hostnameUri.endsWith(...)` on the whole URI
  string (`:71-75`), so `http://abc.onion/login` is **not** caught.
- Image URL: `${iconsServerUrl}/${hostname}/icon.png` (`:79`).
- Only the first URI is used (`CipherViewLikeUtils.uri`).
- IP addresses contain dots and are sent. The dot check is on the whole URI, so a dot-less host
  with a dotted path (`http://nas/index.html`, `http://localhost:8080/a.php`) is sent too; `http://nas`
  alone is not.
- The icon is an `<img>` element, so the browser follows any redirect the icon service sends.

iOS (`IconImageHelper.swift:42-61`) requires a dot, prefixes `http://` when there is no `://`,
requires an `http` prefix, and tries every URI in turn. It does **not** skip `.onion` or `.i2p`.

**Official setting.**
- TS: `showFavicons`, default `true` (`clients/libs/common/src/autofill/services/domain-settings.service.ts:55-57`).
  Label: "Show website icons and retrieve change password URLs" (`apps/desktop/src/locales/en/messages.json:2101-2103`).
- iOS: `disableWebIcons`, stored as `disableFavicon`, default off (= icons shown)
  (`ios/BitwardenShared/Core/Platform/Services/Stores/AppSettingsStore.swift:32, 1010-1011`).

**Vaultwarden 1.37.4 icon service.** Mounted at `{base}/icons/<host>/icon.png`
(`src/main.rs:588`, `src/api/icons.rs:85, 111`). Admin settings: `ICON_SERVICE` (`internal` by
default, or an external service, `src/config.rs:687`), `DISABLE_ICON_DOWNLOAD` (`:616`), and
blocking of non-global IPs, on by default (`:708, 715`). With `ICON_SERVICE` set to an external
service (`bitwarden`, `duckduckgo`, `google` or a template URL), the route answers with a redirect
(`ICON_REDIRECT_CODE`, 302 by default) to that service instead of fetching the icon itself.

**Older servers.** Vaultwarden 1.32.0 already mounts the same route (`src/main.rs:541`,
`src/api/icons.rs:65, 90`), so every Vaultwarden that works with Prizm today serves icons at
`{base}/icons`. A server that has no icon service shows the type icon (Risks). That depends on the
server's setup, not its version, so no legacy adapter is added. A fallback to `icons.bitwarden.net`
is not an option: the Constitution forbids it (D1).

**Prizm today** (checked 2026-10-30).
- `FaviconLoader.swift:35-41`: default base `https://icons.bitwarden.net`, `URLSession.shared`.
  `:58`: `.returnCacheDataElseLoad` (disk `URLCache`). `clearCache()` (`:78-80`) is never called.
  The fetch awaits `session.data` (`:62`) and writes the cache afterwards (`:69`).
- `AppContainer.swift:161`: `FaviconLoader()` with the default; the container exists before login.
- `Domain/Entities/Account.swift:28`: `iconsURL` is `overrides?.icons ?? base/icons`. Unused. The
  override is never set from the UI (`LoginUseCaseImpl.swift:33` passes `overrides: nil`).
- The session lifecycle is in `RootViewModel` (`PrizmApp.swift`): `transitionToVault` (`:491`, the
  one point login and unlock both pass), `signOut` (`:572`), `lockVault` (`:601`), the terminate
  observer (`:405`). It reaches the container through `RootViewModelDependencies` (`:225`), as
  `attachmentTempFiles` does.
- `ItemRowView.swift:120-124`, `ItemDetailView.swift:208-211`,
  `VerificationCodesListView.swift:108-111`: host of `l.firstAddress` (`VaultItem.swift:196`, the
  first URI that has a value) for any scheme. `TrashView` (`:30`) uses `ItemRowView`.
- `FaviconView` keeps the image in `@State` and reloads on `.task(id: domain)` (`:40-46`). It is
  hidden from VoiceOver (`:39`, voiceover-labels).
- `Presentation/Settings/SettingsView.swift`: one Security section with the biometric toggle and
  the clipboard picker, which is an `@AppStorage(ClipboardClearDelay.defaultsKey)` that
  `ClipboardServiceImpl` reads at each copy. The Settings window gets only `authRepository`
  (`PrizmApp.swift:140`); it cannot reach the loader or the account.
- `PrizmAPIClient` adds `Authorization` and `Bitwarden-Client-*` headers only to its own requests
  (`PrizmAPIClient.swift:1382-1383`, client-identification-headers D5) and uses `URLCache.shared`
  (`:658`).

## Goals / Non-Goals

**Goals**
- No request to any host other than the user's server, unless the user allows the server's
  redirect to an outside icon service (D5).
- Users can turn icons off.
- Same URIs produce icon requests as in the official TS clients, with the `.onion`/`.i2p` gap closed.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Icons base from the account, never a default

`FaviconLoader` has no default URL. `configure(iconsBase: URL?)` is called by `RootViewModel`
through `RootViewModelDependencies` (a `faviconLoader` member, like `attachmentTempFiles`):
- in `transitionToVault` (login and unlock), before the vault is shown:
  `account.serverEnvironment.iconsURL`, or `nil` in UI-test mode (`UITestFixtures.isEnabled`), so
  test runs make no lookups for the fake server;
- in `lockVault` and `signOut`: `nil` as the lock starts, next to `vaultBrowserVM.clearSession()`,
  and `reset()` (D4) first in the teardown task.

`configure` is synchronous (the base sits behind a `Mutex`): with an actor hop, a row could ask an
unconfigured loader before the base arrived and keep its type icon for the session, and a lock
would leave the loader configured until its teardown finished, which can wait for the network
(code review 2026-10-30).

With `nil`, `favicon(for:)` returns `nil` without a request. A test asserts that no request goes to
any host other than the configured one. Signing in to another server is sign-out followed by
sign-in, so it passes both points; there is no separate "server change" state.

Icon requests carry no `Authorization` and no `Bitwarden-Client-*` headers, and no cookies: they are
plain image requests, as from the official clients' `<img>`. Organization items are handled exactly
like personal ones (same server, no keys involved).

**Rejected alternative:** fall back to `icons.bitwarden.net` when no server is known. The
Constitution forbids it, and there is nothing to show before sign-in anyway.

### D2. Two settings, read where they are used

- Settings gets a "Privacy" section below "Security", with two toggles:
  - "Show website icons", default on. Help: "Icons are loaded from your server's icon service,
    which may contact the websites."
  - "Allow icons from other services", default off, disabled while icons are off. Help: "If your
    server sends icon requests on to another service, Prizm follows it. That service sees the
    website addresses and your IP address." (D5)
- Stored in `UserDefaults` (UI preference, per CLAUDE.md) as the clipboard setting is: keys
  `icons.showWebsiteIcons` (default `true`) and `icons.allowOtherServices` (default `false`), in a
  Foundation-only `WebsiteIconSettings` (Domain) with the keys, defaults and a reader that takes
  the `UserDefaults` store. `SettingsView` binds them with `@AppStorage`; no view model is needed.
- `FaviconLoader` reads both at each `favicon(for:)` call. With icons off it returns `nil` without a
  request and empties its cache.
- `FaviconView` observes "Show website icons" (`@AppStorage`), reloads on `.task(id:)` of domain and
  setting, and clears its image when the setting is off, so icons already on screen go away.
- The help texts are `.help`, as for the clipboard picker; VoiceOver reads them as the hint. The
  section uses the existing `.formStyle(.grouped)` layout of the window (width 400); no new spacing
  or font tokens are needed.

Default on matches both official clients. After D1 the requests go to the user's own server, and
the server admin's policy applies.

**Rejected alternative:** default off. Safer, but it differs from official clients and from
current Prizm behaviour; users who self-host already control the icon service.

### D3. `WebsiteIconHost.host(for uri: String) -> String?` (Domain)

1. Trim. Empty → `nil`.
2. Starts with `androidapp://` or `iosapp://` (case-insensitive) → `nil`.
3. No `://` and contains `.` → prefix `http://`.
4. Must start with `http://` or `https://` (case-insensitive) → else `nil`.
5. Parse with `URLComponents`; take the host in its encoded form (`URLComponents.encodedHost`, IDNA
   for non-ASCII names, as the browser sends it). No host → `nil`.
6. Without a trailing dot, the host must have at least two labels, none empty (so `..`, `a..b`,
   `.example.com` are refused) → else `nil`.
7. Host ends with `.onion` or `.i2p` (case-insensitive, trailing dot ignored) → `nil`.
8. Return the lowercased host without a trailing dot (one request path and cache key per site).

The URI is the login's first URI that has a value (`firstAddress`; value-less URIs are skipped,
fix-read-mapping-lossless-fields). Match types are not looked at, as in TS: a regular-expression URI
is used if it parses.

Deliberate differences from TS: rule 4 is stricter (`indexOf("http") === 0` also matches
`httpx://`); rule 6 checks the dot on the host, so dot-less intranet hosts with a dotted path are not
sent; rule 7 checks the host, not the whole URI. IP addresses pass, as in official clients;
Vaultwarden blocks non-global IPs by default. As in TS, a scheme-less `mailto:x@y.com` becomes
`http://mailto:x@y.com` with host `y.com`.

### D4. Memory-only cache

- `FaviconLoader` owns a `URLSession` built from `URLSessionConfiguration.ephemeral` with
  `urlCache = nil`, `httpCookieStorage = nil` and `httpShouldSetCookies = false`, and keeps its
  `NSCache`.
- `reset()` empties the `NSCache`, cancels the session's running tasks and bumps a generation
  counter. A fetch that finishes after a reset compares the generation and drops its result (the
  pattern of milestone 1's D-11). `reset()` runs on lock, on sign-out and when icons are turned off:
  the views stop asking while icons are off, so the loader observes `UserDefaults.didChangeNotification`
  and resets itself when the setting goes from on to off. A fetch also drops its result when icons
  are off by the time it finishes.
- One request per host at a time: rows of the same site share the running request (`reset()`
  forgets them).
- Requests use `.reloadIgnoringLocalCacheData`; the in-memory `NSCache` avoids repeat requests in a
  session.
- Older versions left icon responses in `URLCache.shared`, which the API client also uses. Prizm
  calls `URLCache.shared.removeAllCachedResponses()` once per launch; no flag is kept (§VI). Kept
  after the code review of 2026-10-30, which suggested a one-time flag: the call is cheap, and losing
  cached API responses at launch is no loss (Prizm does not rely on HTTP caching, and an encrypted
  vault response is better not kept on disk anyway).

**Rejected alternative:** keep the disk cache, as the desktop app does. It leaves a list of the
user's sites on disk after lock and sign-out, for a small speed gain at launch.

### D5. Redirects to another host need the user's permission

Decided by Christian, 2026-10-30. The session delegate's
`urlSession(_:task:willPerformHTTPRedirection:newRequest:)`:
- follows a redirect whose target has the same scheme, host and port as the icons base (the
  server redirecting within itself);
- follows a redirect to any other origin only when "Allow icons from other services" is on and
  the target is `https` (a plain-`http` redirect would send the host in clear text);
- otherwise cancels it (`completionHandler(nil)`), so the redirect response itself is the result:
  not a 200, so no icon, and the view shows the type icon.

The setting is read at the redirect, so turning it off applies to the next request. Following a
redirect sends the website's host name (in the path the server chose) and the user's IP address to
that service; the setting's help text says so.

**Rejected alternatives:** always follow (as official clients do), which breaks "Nothing leaves your
server" whenever the admin configured an external service; never follow, which gives users of such
servers no icons at all.

## Risks / Trade-offs

- **[Low] More icon requests after each unlock** (no disk cache). The server's own cache headers
  and the in-memory cache limit this.
- **[Low] Bitwarden self-hosted without an icons service** returns errors → type icon shown, as
  today for failures.
- **[Low] Existing on-disk cache entries** from older versions remain in `URLCache.shared`. → Cleared
  at every launch (D4).
- **[Low] Servers with an external `ICON_SERVICE` show type icons** until the user allows other
  services (D5). The README names the setting.

## Open Questions

1. Should Prizm also skip private and loopback IP addresses (RFC 1918, `127.0.0.0/8`, `::1`)?
   Official clients don't. Vaultwarden blocks them server-side by default. Current decision: follow
   official.
2. Should the label mention change-password URLs like the official one? No: Prizm doesn't fetch
   them.
