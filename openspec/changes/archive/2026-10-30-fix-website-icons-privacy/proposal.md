# Proposal

## Why

**Criticality:** P1 (High)
**Findings:** A-01 (`01-auth-session.md`), I-01, I-02, I-03, I-04 (`05-attachments-totp-icons.md`)

Prizm loads website icons from `https://icons.bitwarden.net`, whatever server the user signed in
to (`FaviconLoader.swift:36`, `AppContainer.swift:161`). For every login item, Bitwarden Inc.
receives the host name of its first URI, together with the user's IP address. This affects every
Vaultwarden and self-hosted user, which is everyone Prizm v1 targets.

- It contradicts the README: "the app talks exclusively to your Vaultwarden or Bitwarden instance.
  Nothing leaves your server." (`README.md:101`).
- It breaks the Constitution: "no hardcoded `bitwarden.com` endpoint is permitted in v1. The app
  MUST NOT silently fall back to bitwarden.com" (`CONSTITUTION.md:226-227`).
- It bypasses the server admin's icon policy (Vaultwarden `ICON_SERVICE`, `DISABLE_ICON_DOWNLOAD`,
  blocking of non-global IPs).
- There is no setting to turn icons off (I-02).
- Host names are taken from any scheme (I-03): `ssh://`, `ftp://`, `rdp://`, `androidapp://`,
  `.onion` and `.i2p` hosts, and intranet names all go to the icon server.
- Icon responses are kept in the app's on-disk HTTP cache after lock and sign-out (I-04).

`ServerEnvironment.iconsURL` (`Domain/Entities/Account.swift:28`, `{base}/icons` or an override)
already exists. Nothing uses it.

## Origin of the current behaviour

**Accidental.** The first plan (`a16a8a2`) said "Icons base: `{base}/icons`". The archived spec
required "derive all service endpoints (API, identity, icons) from the base URL"
(`openspec/changes/archive/2026-03-15-vault-browser-ui/specs/vault-browser-ui/spec.md:4`). The
implementation (`bbd22eb`) hard-coded the cloud default and never passed the server's URL. The disk
cache is deliberate (`archive/2026-03-15-vault-browser-ui/design.md:73`).

## What Changes

- **Use the server's icon service.** Icons come from `ServerEnvironment.iconsURL` of the signed-in
  account. With no account, no icons are loaded. The hard-coded cloud URL is removed.
- **Add "Show website icons"** to Settings, on by default as in the official clients. Off means no
  icon requests at all.
- **Redirects to other hosts are refused by default.** When the server's admin points the icon
  service at an outside service (Vaultwarden `ICON_SERVICE`), the server answers with a redirect, and
  following it would send the host name and the user's IP address to that service. Prizm follows a
  redirect to another host only when the user turns on "Allow icons from other services" (off by
  default; decided by Christian 2026-10-30).
- **Only ask for website hosts.** Port the official rules: `http`/`https` URIs, or scheme-less URIs
  with a dot (prefixed with `http://`); skip `androidapp://`, `iosapp://`, `.onion` and `.i2p`.
  Prizm checks the dot and `.onion`/`.i2p` on the host, not on the whole URI, so `http://nas/x.html`,
  `http://localhost:8080/a.php` and `http://abc.onion/login` produce no request.
- **No disk cache.** Icons are cached in memory only and dropped on lock, sign-out and when the
  setting is turned off.
- **README:** keep "Nothing leaves your server", and add that the server's icon service may
  contact the websites, that icons can be turned off, and that "Allow icons from other services"
  lets the server's redirect to an outside icon service through.

## Capabilities

### New Capabilities
- `website-icons`: where website icons come from, which URIs produce an icon request, the user
  setting, and the cache policy.

### Modified Capabilities
_None in this delta._ Related existing spec: `openspec/specs/vault-browser-ui/spec.md` (row shows a
favicon). The archived requirement "Favicons fetched from the Bitwarden icon service" is replaced
by `website-icons`.

## Non-Goals

- Moving `FaviconLoader` (a Data type) out of Presentation views. Presentation currently holds it
  directly (`ItemRowView.swift:19` and others), which bends §II. A separate clean-up.
- Trying later URIs when the first one has no icon (iOS does, TS doesn't). Prizm keeps the first
  URI, as TS.
- Card brand icons.
- Skipping IP addresses. Official clients send them; the server's policy decides (design D3).

## Dependencies

None.

## Impact

- **Domain:** `WebsiteIconHost` utility (pure, Foundation only) that turns a URI string into a host
  or `nil`; `WebsiteIconSettings` with the two `UserDefaults` keys and defaults.
- **Data:** `FaviconLoader` takes its base URL from the account, reads the two settings at each
  request, has a memory-only session with a redirect check, and exposes `reset()`.
- **App:** `RootViewModel` (`PrizmApp.swift`) configures the loader in `transitionToVault` and
  clears it in `lockVault` and `signOut`, through `RootViewModelDependencies`.
- **Presentation:** two Settings toggles in a new "Privacy" section; `FaviconView` follows the
  setting; the three host helpers (`ItemRowView.swift:120-124`, `ItemDetailView.swift:208-211`,
  `VerificationCodesListView.swift:108-111`) use `WebsiteIconHost`. `TrashView` shares `ItemRowView`.
- **Docs:** README privacy paragraph, SECURITY.md network section.
- **No new dependencies.**
- **Security review: yes** (privacy: what leaves the device and to whom).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | Use the server's icons URL; configure on login, unlock, sign-out | 1 d |
| 2 | `WebsiteIconHost` rules and table tests; wire the three call sites | 1 d |
| 3 | Settings toggles, persistence, VoiceOver, views follow the setting | 0.75–1.25 d |
| 4 | Memory-only cache, reset on lock and sign-out, redirect check | 0.75 d |
| 5 | Docs, CHANGELOG, privacy review, rig check | 0.5 d |
| **Total** | | **4–4.5 d** |
