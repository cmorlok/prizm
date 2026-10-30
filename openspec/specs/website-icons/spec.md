# website-icons Specification

## Purpose
Where website icons come from and what their requests reveal: only the signed-in server's icon service, without credentials, only for website hosts, never while locked or signed out, with two user settings (icons on or off; redirects to other services) and no disk cache.

## Requirements

### Requirement: Icons come only from the signed-in server's icon service
The system SHALL request website icons only from the icons URL of the signed-in account's server environment (`{base}/icons`, or the icons override when one is set). The system SHALL NOT send an icon request to any other host, except by following a redirect the user allowed (requirement "Redirects to other services need the user's permission"), and SHALL NOT send icon requests when no account is signed in or the vault is locked.

#### Scenario: Vaultwarden user
- **GIVEN** a user signed in to `https://vault.example.com` with no icons override
- **WHEN** the item list shows a login with URI `https://github.com/login`
- **THEN** the only icon request SHALL be `https://vault.example.com/icons/github.com/icon.png`
- **AND** no request SHALL go to `icons.bitwarden.net`

#### Scenario: Icons override (unit level; the UI never sets one)
- **GIVEN** the loader is configured from a server environment with an icons override `https://icons.example.net`
- **WHEN** it is asked for the icon of `github.com`
- **THEN** the request SHALL go to `https://icons.example.net/github.com/icon.png`

#### Scenario: Locked vault
- **GIVEN** the vault was locked
- **WHEN** the loader is asked for an icon
- **THEN** no request SHALL be sent and no icon SHALL be returned

### Requirement: Icon requests carry no credentials
Icon requests SHALL carry no authorization header, no client identification headers and no cookies, and their responses SHALL NOT set cookies.

#### Scenario: Plain image request
- **WHEN** the system requests a website icon
- **THEN** the request SHALL have no `Authorization` header, no `Bitwarden-Client-*` header and no `Cookie` header

### Requirement: Users can turn website icons off
The system SHALL provide a "Show website icons" setting, on by default. When it is off, the system SHALL send no icon requests, SHALL show the item type icon instead, and SHALL remove icons already shown.

#### Scenario: Turning icons off
- **GIVEN** website icons are on and the item list shows icons
- **WHEN** the user turns off "Show website icons" in Settings
- **THEN** the list SHALL show type icons
- **AND** no further icon requests SHALL be sent
- **AND** VoiceOver SHALL read the toggle as "Show website icons" with its state

### Requirement: Redirects to other services need the user's permission
The system SHALL provide an "Allow icons from other services" setting, off by default and unavailable while website icons are off. When the icon service answers with a redirect to a different scheme, host or port than the icons URL, the system SHALL follow it only when this setting is on and the redirect target uses `https`, and otherwise SHALL show the item type icon. A redirect to the same scheme, host and port SHALL be followed.

#### Scenario: Redirect to an outside service, setting off
- **GIVEN** "Allow icons from other services" is off
- **WHEN** the server answers an icon request with a 302 to `https://icons.bitwarden.net/github.com/icon.png`
- **THEN** no request SHALL go to `icons.bitwarden.net`
- **AND** the row SHALL show the item type icon

#### Scenario: Redirect to an outside service, setting on
- **GIVEN** "Allow icons from other services" is on
- **WHEN** the server answers an icon request with a 302 to `https://icons.bitwarden.net/github.com/icon.png`
- **THEN** the system SHALL request that URL and show the icon it returns

#### Scenario: Redirect to plain http, setting on
- **GIVEN** "Allow icons from other services" is on and the icons URL uses `https`
- **WHEN** the server answers with a 302 to `http://icons.example.net/github.com.png`
- **THEN** no request SHALL go to `icons.example.net`
- **AND** the row SHALL show the item type icon

#### Scenario: Redirect within the server
- **WHEN** the server answers an icon request with a redirect to another path on the same scheme, host and port
- **THEN** the system SHALL follow it, whatever the setting

### Requirement: Only website hosts produce icon requests
The system SHALL derive an icon host only from the first URI of a login that has a value, and only when that URI is `http`/`https` or scheme-less with a dot, its host contains a dot, and its host does not end in `.onion` or `.i2p`. Scheme-less URIs SHALL be treated as `http://` URIs. `androidapp://` and `iosapp://` URIs SHALL NOT produce a request. Non-ASCII host names SHALL be sent in their IDNA (punycode) form.

#### Scenario: Host rules
- **GIVEN** a login whose first URI with a value is one of the values below
- **WHEN** the system derives the icon host
- **THEN** the result SHALL be:
- **AND** `https://www.example.com/login` → `www.example.com`
- **AND** `example.com/login` → `example.com`
- **AND** `ssh://git.example.com` → none
- **AND** `ftp://files.example.com` → none
- **AND** `androidapp://com.example.app` → none
- **AND** `http://localhost:8080` → none
- **AND** `http://localhost:8080/a.php` → none
- **AND** `http://nas` → none
- **AND** `http://nas/index.html` → none
- **AND** `http://abcdef.onion/login` → none
- **AND** `https://site.i2p` → none
- **AND** `https://192.0.2.10` → `192.0.2.10`
- **AND** `https://bücher.de` → `xn--bcher-kva.de`
- **AND** `mailto:x@y.com` → `y.com`

#### Scenario: First URI without a value
- **GIVEN** a login whose first URI has no value and whose second URI is `https://example.com`
- **WHEN** the system derives the icon host
- **THEN** the result SHALL be `example.com`

### Requirement: Icons are not cached on disk
The system SHALL keep fetched icons in memory only, and SHALL discard them when the vault locks, when the user signs out, and when the setting is turned off. A request that finishes after such a discard SHALL NOT add its icon to the cache.

#### Scenario: Sign-out
- **GIVEN** the item list showed icons for several sites
- **WHEN** the user signs out
- **THEN** no icon image or icon response SHALL remain in memory or in an on-disk cache of Prizm

#### Scenario: Lock during a request
- **GIVEN** an icon request is running
- **WHEN** the vault locks before it finishes
- **THEN** its icon SHALL NOT be in the cache afterwards
