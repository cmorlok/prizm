# Vaultwarden test rig

A local Vaultwarden server for checking Prizm against real server behaviour. It runs as services
of the devcontainer's compose project, behind the `rig` profile, so it starts only when you ask for
it. All rig commands run **on the Mac**; the container has no Docker access.

| Service | What | Reached at |
|---|---|---|
| `vaultwarden-1-37-4` | Vaultwarden 1.37.4, the server under test | `http://vaultwarden-1-37-4` (container) |
| `vaultwarden-1-37-3` | Vaultwarden 1.37.3, the comparison version and the fixture-authoring server | `http://vaultwarden-1-37-3` (container) |
| `edge` | nginx with TLS in front of one of them | `https://localhost:8443` (Mac, loopback only) |

Both images are pinned by tag and digest in `.devcontainer/compose.yaml`.

Data lives in `dev-vault/` in the repo (git-ignored, visible on the Mac and at
`/workspaces/prizm/dev-vault` in the container):

| Path | Content |
|---|---|
| `dev-vault/1.37.4/`, `dev-vault/1.37.3/` | one Vaultwarden data dir per version (`db.sqlite3`, `rsa_key.pem`, attachments) |
| `dev-vault/snapshots/<label>/` | consistent copies, with `.rig-snapshot` (version, image digest, date) |
| `dev-vault/replaced/` | data dirs moved aside by a restore (delete them when no longer needed) |
| `dev-vault/certs/` | the localhost leaf `vw.crt` and its key `vw.key` |
| `dev-vault/nginx/` | `upstream.conf` (which version edge serves) and `flag/` (feature flag) |
| `dev-vault/logs/cipher-bodies.log` | cipher create and update request bodies seen by edge (ciphertext only) |
| `dev-vault/evidence/` | recorded experiment results |
| `dev-vault/.env` | the fixture account password (never committed) |

## First start

1. Check the script under the Mac's bash:
   ```bash
   scripts/host/vaultwarden.sh selftest
   ```
2. Create the certificate and trust it (in Terminal, not over SSH: macOS asks for your password):
   ```bash
   scripts/host/vaultwarden.sh cert
   ```
   It creates a self-signed leaf for `localhost` and `127.0.0.1`, trusts it **for SSL only** in
   your login keychain (`security add-trusted-cert -r trustRoot -p ssl`), and verifies it. There
   is deliberately no local root CA: a CA key could sign a certificate for any site, this trust
   covers one certificate.
3. Start a version:
   ```bash
   scripts/host/vaultwarden.sh up 1.37.3
   ```
4. Open `https://localhost:8443` in Chrome and Safari. The web vault must load without a
   certificate warning. If Chrome still warns, quit and restart it.

`scripts/host/vaultwarden.sh status` shows the services, which version edge serves, the flag, the
certificate expiry and the server version answering at `https://localhost:8443`.

## Versions

Each version has its own data dir. `up <version>` starts that version and edge, and points edge at
it. The other version keeps running if it was running; edge serves one at a time. Switch with
another `up`. Stop with `down 1.37.3`, `down 1.37.4`, `down edge` or `down all`.

A database that Vaultwarden 1.37.4 has migrated must never be opened by 1.37.3. `restore` refuses
a snapshot made on a newer version than the target.

## Feature flag `cipher-key-encryption`

Vaultwarden cannot send this flag, so edge adds it to `/api/config`:
```bash
scripts/host/vaultwarden.sh flag on    # or: flag off
```
Clients read flags when they log in: log the extension or web vault out and in again after a
change. `pm-19148-innovation-archive` (archiving) is always sent by Vaultwarden and needs no flag.

## Slow cipher updates (lock during save)

To lock the app while a save is still in flight, edge can slow the answer to `PUT /api/ciphers/{id}`.
The server stores the edit at once; only the answer to the client trickles:
```bash
scripts/host/vaultwarden.sh delay on 200   # RATE in bytes per second, default 200
scripts/host/vaultwarden.sh status         # shows "delay PUT /api/ciphers answers: on (200 B/s)"
scripts/host/vaultwarden.sh delay off      # turn it off after the check
```
- GET, POST and every other path are never throttled, so refreshes keep their 10 s timeout.
- It is off by default: an empty `dev-vault/nginx/delay/` directory means off, as for the feature flag.
- `nginx.conf` is mounted into edge as a single file. After a checkout that changes it, recreate
  edge (`down edge`, then `up 1.37.4`); `delay on` and `delay off` only need the reload they do.
- The switch lives on the branch `chore/rig-delay` until its pull request is merged into `develop`.

## Fixture account

`prizm-fixture@example.com`, PBKDF2 with the default 600000 iterations. The password is in
`dev-vault/.env`. It is a throwaway account on a loopback server and may appear in recorded
evidence; never reuse it anywhere else.

## Snapshot and restore

```bash
scripts/host/vaultwarden.sh snapshot 1.37.3 fixture-v1
scripts/host/vaultwarden.sh restore fixture-v1 1.37.4
```
- `snapshot` stops the service (Vaultwarden runs SQLite in WAL mode, so a live copy can be torn),
  copies the data dir to `<label>.partial`, requires `pragma integrity_check` to answer `ok`,
  writes `.rig-snapshot`, renames it to `<label>`, and restarts the service if it was running. An
  existing label is never overwritten. An interrupted snapshot leaves only `<label>.partial`,
  which `restore` does not accept.
- `restore` stops the target service, moves its current data dir to `dev-vault/replaced/`,
  copies the snapshot in, and restarts the service if it was running.
- **After a restore, log in again** in every client and probe: devices and tokens created after
  the snapshot are gone.

## Which items have their own key

```bash
scripts/host/vaultwarden.sh keyed 1.37.3
```
Lists every cipher with its type, whether it has its own `key` (and its EncString prefix, `2.`),
whether it belongs to an organization, then the archived items and `keyed=<n> total=<m>`. While
the service runs, it reads a consistent backup that Vaultwarden writes itself, then deletes it.

## Removing the certificate trust

```bash
scripts/host/vaultwarden.sh status            # shows the certificate
security remove-trusted-cert dev-vault/certs/vw.crt
security delete-certificate -Z <SHA-1> "$HOME/Library/Keychains/login.keychain-db"
```
`cert` prints both commands with the right SHA-1. `status` warns 30 days before the certificate
expires; then run `cert --force` and restart Chrome.

## Troubleshooting

- **HTTP 429 on login:** Vaultwarden allows 10 logins per 60 seconds per IP. Wait a minute;
  probes keep their token and log in again only after a 401.
- **`vaultwarden-1-37-X` does not resolve in the container:** the service is not running
  (`status`), or `prizm-dev` is still the old non-compose container: remove it once with
  `docker rm -f prizm-dev` and reopen the devcontainer.
- **edge answers 502:** the version edge points at is not running. Run `up <version>`.
- **edge cannot resolve its upstream under your Docker runtime:** fall back to a static upstream
  (`proxy_pass http://vaultwarden-1-37-X;`) and let `up` recreate edge on a version switch.

> **Never**
> - run `docker compose down` or `docker compose up` without service names against this project.
>   `down` removes `prizm-dev`; a bare `up` recreates it. The script names every service.
> - mount the Docker socket into `prizm-dev`. Rig control stays on the Mac.
