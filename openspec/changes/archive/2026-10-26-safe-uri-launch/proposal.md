# Proposal

## Why

**Criticality:** P2 (Medium)
**Findings:** CF-06 (`06-client-features.md`)

Each website row in a login's detail view has an "Open in browser" button. Prizm builds its target
with `URL(string: uri.uri)` and hands any result to macOS (`LoginDetailView.swift:64`,
`FieldRowView.swift:102-117`). There is no check of the scheme:

- **Any scheme is launched.** `file:` URLs open local files and applications; `smb:` mounts a
  share; custom app schemes trigger whatever app registered them. An organization item is written
  by other members, so a shared item can carry such a URI. One click runs it.
- **Scheme-less URIs don't open.** `example.com/login` (common in imported vaults) becomes a
  relative URL, and the button does nothing.

Official clients launch only an allow-list of schemes and add `http://` to scheme-less URIs.

## Origin of the current behaviour

**Accidental.** No spec or design mentions a scheme check. The `url: URL(string: uri.uri)` call was
added in `c95e172` (2026-04-03, v1 release prep) without a decision record.

## What Changes

- **Allow-list.** The button appears only for URIs whose scheme is on the official list:
  `https://`, `http://`, `ssh://`, `ftp://`, `sftp://`, `irc://`, `vnc://`, `rdp://`, `ms-rd:`,
  `chrome://`, `iosapp://`, `androidapp://`. Matching is case-insensitive, as in the official
  clients.
- **Only if the Mac can open it.** Among allowed schemes, the button is hidden when no app on the
  Mac handles the scheme (for example `androidapp://`).
- **Scheme-less URIs** that have a domain get `http://` in front, as in the official TS clients.
- **Regular-expression URIs** (match type "Regular expression") get no button: they are patterns,
  not addresses. Official clients do the same.

## Capabilities

### New Capabilities
- `uri-launch`: which stored URIs Prizm offers to open, and the URL it opens.

### Modified Capabilities
_None in this delta._ Related existing spec: `openspec/specs/detail-card-view/spec.md` (website
rows).

## Non-Goals

- Opening URIs from the item list (no such action today).
- A confirmation dialog before opening. Official clients don't have one; the allow-list removes the
  dangerous cases.
- A public-suffix list for "has a domain" (design D2). It would be a new dependency.

## Dependencies

None.

## Impact

- **Domain:** `URILaunchPolicy.launchURL(for: LoginURI) -> URL?` (Foundation only).
- **Presentation:** `LoginDetailView` passes the policy's URL to `FieldRowView`; `FieldRowView`
  shows the button only when a URL is given and the Mac has a handler. The existing VoiceOver
  label and hint stay.
- **No new dependencies.**
- **Security review: yes** (light: input validation on a launch path).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | `URILaunchPolicy` with table tests | 0.5 d |
| 2 | Wire into the detail view; handler check; UI test | 0.5–1 d |
| 3 | Security review, CHANGELOG | 0.25 d |
| **Total** | | **1.25–1.75 d** |
