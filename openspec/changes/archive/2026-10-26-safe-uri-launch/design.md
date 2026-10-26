# Design

## Context

**Official TS clients.** Sources at HEAD 2026-10-23.
- `clients/libs/common/src/platform/misc/safe-urls.ts:3-19`, `UrlType.CipherUri`: `https://`,
  `http://`, `ssh://`, `ftp://`, `sftp://`, `irc://`, `vnc://`, `rdp://`, `ms-rd:`, `chrome://`,
  `iosapp://`, `androidapp://`. `SafeUrls.canLaunch` (`:25-39`) lowercases the URI and checks the
  prefix. The audit row CF-06 lists the same set without `ms-rd:`, which has since been added.
- `clients/libs/common/src/vault/models/view/login-uri.view.ts:94-104` (`canLaunch`): false when
  the match type is Regular Expression; otherwise `SafeUrls.canLaunch(launchUri, CipherUri)`.
- `login-uri.view.ts:106-113` (`launchUri`): if the URI has no `://` and `Utils.getDomain(uri)` is
  not empty, prefix `http://`.
- `clients/libs/common/src/platform/misc/utils.ts:483-512` (`getDomain`): returns the host for
  `localhost` and IP addresses, otherwise the registrable domain from the public suffix list
  (`tldts`), otherwise null.

**Official iOS.** `ios/BitwardenShared/UI/Vault/VaultItem/ViewItem/ViewItemDetailsView.swift:439-447`
shows the launch button when `URL(string: uri)?.sanitized` has valid components. `sanitized`
(`ios/BitwardenKit/Core/Platform/Extensions/URL.swift:23-25`, `String.httpsNormalized()` in
`String.swift:170-181`) prefixes `https://` to anything that doesn't start with `http://` or
`https://`. In effect iOS only launches web URLs, and uses `https://` for scheme-less ones.

**Prizm today.**
- `Presentation/Vault/Detail/LoginDetailView.swift:60-66`: `FieldRowView(…, url: URL(string: uri.uri))`.
- `Presentation/Components/FieldRowView.swift:102-117`: `Link(destination: link)` for any non-nil
  URL; label "Open \(label)", hint "Opens in browser".
- `Domain/Entities/VaultItem.swift:80-93`: `LoginURI.matchType` includes `.regularExpression`.

## Goals / Non-Goals

**Goals**
- Prizm never launches a scheme the official desktop and browser clients wouldn't.
- Scheme-less website URIs open.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Follow the TS allow-list

`URILaunchPolicy` holds the 12 prefixes from `safe-urls.ts` and matches them case-insensitively
against the (possibly prefixed) URI. The list lives in one `enum` with a comment pointing to the
source file.

**Rejected alternative:** iOS behaviour (web only). Simpler, but `ssh://`, `vnc://` and `rdp://`
have real handlers on macOS (Terminal, Screen Sharing, Microsoft Remote Desktop), and the desktop
client offers them.

### D2. Scheme-less URIs: `http://` when there is a domain

If the trimmed URI has no `://`: build `http://<uri>` and parse it. Launch it only if the host is
`localhost`, an IP address, or contains a dot. This approximates `Utils.getDomain` without a public
suffix list. Known difference: Prizm opens `foo.notarealtld`; the TS client doesn't. Harmless.

`http://` follows the TS clients (the desktop app is the closest analogue). iOS uses `https://`. A
site that supports HTTPS usually redirects. Open Question 1.

### D3. No button for regular-expression URIs

`matchType == .regularExpression` → `nil`, as in `login-uri.view.ts:98`.

### D4. Hide the button when the Mac has no handler

After D1–D3, Presentation checks `NSWorkspace.shared.urlForApplication(toOpen:)`. `nil` → no
button. This keeps `androidapp://` and `iosapp://` from showing a button that does nothing. The
check is UX only; D1 is the security control and lives in Domain.

### D5. Placement

`URILaunchPolicy.launchURL(for: LoginURI) -> URL?` in `Domain/Utilities` (Foundation only, pure,
table-tested). `LoginDetailView` calls it and passes the result as `url:`. `FieldRowView` keeps its
API.

## Risks / Trade-offs

- **[Low] Users with custom-scheme URIs** (for example `obsidian://`) lose the button. → That is
  the official behaviour. They can still copy the URI.
- **[Low] Plain `http://`** for scheme-less URIs may hit a site without HTTPS redirect. → Same as
  the official desktop client.

## Open Questions

1. `http://` (TS) or `https://` (iOS) for scheme-less URIs? Current decision: `http://`, as the
   desktop client. The maintainer may prefer `https://`.
