#!/usr/bin/env bash
# Vaultwarden test rig control. Run it on the Mac; the container has no Docker access.
#
#   scripts/host/vaultwarden.sh up <1.37.3|1.37.4>      # start that version and edge; edge serves it
#   scripts/host/vaultwarden.sh down <1.37.3|1.37.4|edge|all>   # stop and remove those rig services
#   scripts/host/vaultwarden.sh status                  # services, upstream, flag, cert, server version
#   scripts/host/vaultwarden.sh cert [--force]          # create the localhost leaf, trust it for SSL
#   scripts/host/vaultwarden.sh flag <on|off>           # cipher-key-encryption in /api/config
#   scripts/host/vaultwarden.sh snapshot <version> <label>   # consistent copy of a data dir
#   scripts/host/vaultwarden.sh restore <label> <version>    # replace a data dir with a snapshot
#   scripts/host/vaultwarden.sh keyed <version>         # which ciphers have their own key
#   scripts/host/vaultwarden.sh selftest                # offline checks; runs anywhere
#
# Clients reach the rig at https://localhost:8443 (edge, loopback only). Data lives in dev-vault/
# (git-ignored): one data dir per version, snapshots/, certs/, nginx/, logs/. Rig services are
# always named explicitly; this script never tears the compose project down and never starts it
# without service names, because either would remove or recreate prizm-dev.
# See .devcontainer/rig/RUNBOOK.md.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}"; }

vault="${PRIZM_REPO_ROOT}/dev-vault"
compose_file="${PRIZM_REPO_ROOT}/.devcontainer/compose.yaml"
san_config="${PRIZM_REPO_ROOT}/.devcontainer/rig/openssl-san.cnf"
crt="${vault}/certs/vw.crt"
key="${vault}/certs/vw.key"
flag_file_name="cipher-key-encryption.conf"
login_keychain="${HOME}/Library/Keychains/login.keychain-db"

# --- pure helpers (covered by selftest) ---------------------------------------------------------

# version_gt A B: true when A is newer than B, compared numerically per component (1.37.10 > 1.37.4).
version_gt() {
  local a="$1" b="$2" x y
  while [[ -n "${a}" || -n "${b}" ]]; do
    x="${a%%.*}"; y="${b%%.*}"
    x="${x:-0}"; y="${y:-0}"
    if (( 10#${x} > 10#${y} )); then return 0; fi
    if (( 10#${x} < 10#${y} )); then return 1; fi
    if [[ "${a}" == *.* ]]; then a="${a#*.}"; else a=""; fi
    if [[ "${b}" == *.* ]]; then b="${b#*.}"; else b=""; fi
  done
  return 1
}

valid_label() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *.partial ]]
}

# service_for <version>: prints the compose service of a supported version, or fails.
service_for() {
  case "$1" in
    1.37.3) echo "vaultwarden-1-37-3" ;;
    1.37.4) echo "vaultwarden-1-37-4" ;;
    *) return 1 ;;
  esac
}

require_version() {
  service_for "$1" >/dev/null || die "unsupported version '$1'. Valid versions: 1.37.3, 1.37.4"
}

# shellcheck disable=SC2016 # $vw_upstream is an nginx variable, not a shell one
upstream_line() { printf 'set $vw_upstream http://%s;\n' "$(service_for "$1")"; }

# Vaultwarden's SUPPORTED_FEATURE_FLAGS cannot deliver cipher-key-encryption, so edge rewrites
# /api/config. The body is compact JSON and featureStates is never empty (Vaultwarden always adds
# pm-19148-innovation-archive), so the trailing comma keeps it valid JSON.
flag_line() {
  printf "sub_filter '%s' '%s';\n" '"featureStates":{' '"featureStates":{"cipher-key-encryption":true,'
}

# --- docker helpers ---------------------------------------------------------------------------

project() {
  local p
  p="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${PRIZM_CONTAINER}" 2>/dev/null || true)"
  if [[ -z "${p}" || "${p}" == "<no value>" ]]; then p="prizm"; fi
  echo "${p}"
}

compose() { docker compose -p "$(project)" -f "${compose_file}" "$@"; }

is_running() { compose ps --status running --services 2>/dev/null | grep -qx "$1"; }

require_docker() { command -v docker >/dev/null || die "docker not found on PATH."; }

start_services() { compose up -d --no-deps --wait "$@"; }

stop_services() {
  compose stop -t 30 "$@"
  compose rm -f "$@"
}

# image_digest <service>: repo digest of the image the service's container was created from.
image_digest() {
  local container image
  container="$(compose ps -a -q "$1" 2>/dev/null | head -1)"
  [[ -n "${container}" ]] || return 0
  image="$(docker inspect -f '{{.Image}}' "${container}")"
  docker inspect -f '{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true
}

reload_edge() {
  if is_running edge; then compose exec -T edge nginx -s reload; fi
}

# --- subcommands ------------------------------------------------------------------------------

cmd_up() {
  local version="${1:-}" service edge_was_running=0
  require_version "${version}"
  service="$(service_for "${version}")"
  [[ -f "${crt}" && -f "${key}" ]] || die "no rig certificate. Run: scripts/host/vaultwarden.sh cert"
  mkdir -p "${vault}/${version}" "${vault}/nginx/flag" "${vault}/logs"
  upstream_line "${version}" > "${vault}/nginx/upstream.conf"
  if is_running edge; then edge_was_running=1; fi
  start_services "${service}" edge
  # A running edge keeps its old upstream until it re-reads the config.
  if [[ "${edge_was_running}" == 1 ]]; then compose exec -T edge nginx -s reload; fi
  cmd_status
}

cmd_down() {
  case "${1:-}" in
    1.37.3|1.37.4) stop_services "$(service_for "$1")" ;;
    edge) stop_services edge ;;
    all) stop_services vaultwarden-1-37-4 vaultwarden-1-37-3 edge ;;
    *) die "down needs one of: 1.37.3, 1.37.4, edge, all" ;;
  esac
}

cmd_status() {
  local svc upstream="none" flag="off" config
  log "Rig services (project $(project))"
  for svc in vaultwarden-1-37-4 vaultwarden-1-37-3 edge; do
    if is_running "${svc}"; then echo "  ${svc}: running"; else echo "  ${svc}: stopped"; fi
  done
  if [[ -f "${vault}/nginx/upstream.conf" ]]; then
    upstream="$(sed -n 's/.*http:\/\/\([^;]*\);.*/\1/p' "${vault}/nginx/upstream.conf")"
  fi
  [[ -f "${vault}/nginx/flag/${flag_file_name}" ]] && flag="on"
  echo "  edge upstream: ${upstream}"
  echo "  flag cipher-key-encryption: ${flag}"
  if [[ -f "${crt}" ]]; then
    echo "  cert: $(openssl x509 -in "${crt}" -noout -subject -enddate | tr '\n' ' ')"
    openssl x509 -in "${crt}" -noout -checkend 2592000 >/dev/null \
      || warn "the rig certificate expires within 30 days. Run: scripts/host/vaultwarden.sh cert --force"
  else
    echo "  cert: missing (scripts/host/vaultwarden.sh cert)"
  fi
  if config="$(curl -fsS --max-time 5 https://localhost:8443/api/config 2>/dev/null)"; then
    # /api/config names the Bitwarden server version Vaultwarden is compatible with, not its own
    # version; which Vaultwarden answers is the edge upstream above.
    echo "  Bitwarden API version: $(printf '%s' "${config}" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)"
    if printf '%s' "${config}" | grep -q 'cipher-key-encryption'; then
      echo "  /api/config: contains cipher-key-encryption"
    else
      echo "  /api/config: no cipher-key-encryption"
    fi
  else
    echo "  server: https://localhost:8443/api/config not reachable"
  fi
  if [[ -d "${vault}/snapshots" ]]; then
    local snap
    for snap in "${vault}"/snapshots/*; do
      [[ -d "${snap}" ]] || continue
      echo "  snapshot $(basename "${snap}"): $(sed -n 's/^version=//p' "${snap}/.rig-snapshot" 2>/dev/null || echo "incomplete")"
    done
  fi
}

# Security goal: give the rig real TLS, so Prizm (App Transport Security), the browser extension
# and the web vault connect to https://localhost:8443 without exceptions or disabled checks.
# Algorithm: a self-signed X.509 leaf, RSA 2048, SHA-256, 365 days, SAN localhost and 127.0.0.1,
# CA:FALSE, extendedKeyUsage serverAuth (RFC 5280 §4.2.1.6, §4.2.1.9, §4.2.1.12).
# Trusted in the login keychain for the SSL policy only (-p ssl), not system-wide.
# Intentionally not done: no local root CA. A CA key could sign a certificate for any host; this
# trust covers exactly one certificate for localhost. The private key stays unencrypted in the
# git-ignored dev-vault/certs, because it protects only a loopback rig with throwaway data.
cmd_cert() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1
  command -v openssl >/dev/null || die "openssl not found."
  mkdir -p "${vault}/certs"
  if [[ -f "${crt}" && "${force}" == 0 ]]; then
    log "Certificate exists: ${crt} (use --force for a new one)"
  else
    log "Creating the localhost leaf certificate"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes -config "${san_config}" \
      -keyout "${key}" -out "${crt}"
    chmod 600 "${key}"
  fi
  log "Trusting it for SSL in the login keychain (approve the macOS prompt; needs a GUI session, not SSH)"
  security add-trusted-cert -r trustRoot -p ssl -k "${login_keychain}" "${crt}"
  security verify-cert -c "${crt}" -p ssl -s localhost
  echo "SHA-256 fingerprint: $(openssl x509 -in "${crt}" -noout -fingerprint -sha256 | cut -d= -f2)"
  echo "To remove the trust later:"
  echo "  security remove-trusted-cert \"${crt}\""
  echo "  security delete-certificate -Z $(openssl x509 -in "${crt}" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :) \"${login_keychain}\""
  if is_running edge; then compose exec -T edge nginx -s reload; fi
}

cmd_flag() {
  mkdir -p "${vault}/nginx/flag"
  case "${1:-}" in
    on) flag_line > "${vault}/nginx/flag/${flag_file_name}" ;;
    # nginx includes the directory with a glob; a glob matching nothing is valid, while a
    # missing single include file would stop nginx from starting. So "off" is an empty directory.
    off) rm -f "${vault}/nginx/flag/${flag_file_name}" ;;
    *) die "flag needs on or off" ;;
  esac
  reload_edge
  log "Flag cipher-key-encryption: $1 (clients read flags at login: log out and in again)"
}

# Copies a stopped data dir: Vaultwarden runs SQLite in WAL mode, so a copy of a running database
# can be torn. The copy becomes usable only after integrity_check, under its final name.
cmd_snapshot() {
  local version="${1:-}" label="${2:-}" service was_running=0 dst partial digest
  require_version "${version}"
  valid_label "${label}" || die "invalid label '${label}' (letters, digits, . _ -; not ending in .partial)"
  service="$(service_for "${version}")"
  dst="${vault}/snapshots/${label}"
  partial="${dst}.partial"
  [[ -e "${dst}" ]] && die "snapshot ${label} exists; choose another label"
  [[ -f "${vault}/${version}/db.sqlite3" ]] || die "no database in dev-vault/${version}; nothing to snapshot"
  command -v sqlite3 >/dev/null || die "sqlite3 not found."
  mkdir -p "${vault}/snapshots"
  rm -rf "${partial}"
  if is_running "${service}"; then was_running=1; compose stop -t 30 "${service}"; fi
  digest="$(image_digest "${service}")"
  if ! cp -Rp "${vault}/${version}" "${partial}" \
     || [[ "$(sqlite3 -readonly "${partial}/db.sqlite3" 'pragma integrity_check;')" != "ok" ]]; then
    rm -rf "${partial}"
    if [[ "${was_running}" == 1 ]]; then start_services "${service}"; fi
    die "snapshot failed (copy or integrity_check); dev-vault/${version} is unchanged"
  fi
  printf 'version=%s\nimage=%s\ndate=%s\nsource=dev-vault/%s\n' \
    "${version}" "${digest}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${version}" > "${partial}/.rig-snapshot"
  mv "${partial}" "${dst}"
  if [[ "${was_running}" == 1 ]]; then start_services "${service}"; fi
  log "Snapshot ${label} of ${version} written"
}

cmd_restore() {
  local label="${1:-}" version="${2:-}" src snap_version service was_running=0 aside
  require_version "${version}"
  valid_label "${label}" || die "invalid label '${label}'"
  src="${vault}/snapshots/${label}"
  [[ -d "${src}" && -f "${src}/.rig-snapshot" ]] || die "no complete snapshot named ${label}"
  snap_version="$(sed -n 's/^version=//p' "${src}/.rig-snapshot")"
  # A database migrated by a newer Vaultwarden must never reach an older one (no downgrades).
  if version_gt "${snap_version}" "${version}"; then
    die "snapshot ${label} was made on ${snap_version}, newer than ${version}; downgrades are unsupported"
  fi
  service="$(service_for "${version}")"
  if is_running "${service}"; then was_running=1; compose stop -t 30 "${service}"; fi
  mkdir -p "${vault}/replaced"
  if [[ -d "${vault}/${version}" ]]; then
    aside="${vault}/replaced/${version}-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "${vault}/${version}" "${aside}"
    log "Previous data moved to ${aside#"${PRIZM_REPO_ROOT}/"}"
  fi
  rm -rf "${vault}/${version}.partial"
  cp -Rp "${src}" "${vault}/${version}.partial"
  rm -f "${vault}/${version}.partial/.rig-snapshot"
  mv "${vault}/${version}.partial" "${vault}/${version}"
  if [[ "${was_running}" == 1 ]]; then start_services "${service}"; fi
  log "Restored ${label} into ${version}. Clients and probes must log in again."
}

cmd_keyed() {
  local version="${1:-}" service db backup="" before
  require_version "${version}"
  command -v sqlite3 >/dev/null || die "sqlite3 not found."
  service="$(service_for "${version}")"
  if is_running "${service}"; then
    # The live database is in WAL mode; read a consistent copy made by Vaultwarden itself.
    before="$(find "${vault}/${version}" -maxdepth 1 -name 'db_*.sqlite3' | sort | tail -1)"
    compose exec -T "${service}" /vaultwarden backup >/dev/null
    backup="$(find "${vault}/${version}" -maxdepth 1 -name 'db_*.sqlite3' | sort | tail -1)"
    [[ -n "${backup}" && "${backup}" != "${before}" ]] || die "Vaultwarden did not write a backup"
    db="${backup}"
  else
    db="${vault}/${version}/db.sqlite3"
    [[ -f "${db}" ]] || die "no database in dev-vault/${version}"
  fi
  # The column is "key" (users and attachments use akey).
  sqlite3 -readonly "${db}" \
    'select substr(uuid,1,8), atype, ("key" is not null), substr("key",1,2), (organization_uuid is not null) from ciphers order by created_at;'
  sqlite3 -readonly "${db}" 'select substr(cipher_uuid,1,8), archived_at from archives;'
  echo "keyed=$(sqlite3 -readonly "${db}" 'select count(*) from ciphers where "key" is not null;') total=$(sqlite3 -readonly "${db}" 'select count(*) from ciphers;')"
  if [[ -n "${backup}" ]]; then rm -f "${backup}"; fi
}

cmd_selftest() {
  local failures=0 tmp v
  fail() { echo "selftest FAIL: $*"; failures=$((failures + 1)); }
  version_gt 1.37.10 1.37.4 || fail "1.37.10 > 1.37.4"
  version_gt 1.37.4 1.37.3 || fail "1.37.4 > 1.37.3"
  if version_gt 1.37.3 1.37.4; then fail "not 1.37.3 > 1.37.4"; fi
  if version_gt 1.37.4 1.37.4; then fail "not 1.37.4 > 1.37.4"; fi
  for v in fixture-v1 post-experiments-1.37.4; do valid_label "${v}" || fail "label ${v} accepted"; done
  for v in "" "../x" "a b" "x.partial"; do
    if valid_label "${v}"; then fail "label '${v}' rejected"; fi
  done
  [[ "$(service_for 1.37.3)" == "vaultwarden-1-37-3" ]] || fail "1.37.3 maps to vaultwarden-1-37-3"
  [[ "$(service_for 1.37.4)" == "vaultwarden-1-37-4" ]] || fail "1.37.4 maps to vaultwarden-1-37-4"
  if service_for 1.38.0 >/dev/null; then fail "1.38.0 rejected"; fi
  tmp="$(mktemp -d)"
  upstream_line 1.37.3 > "${tmp}/upstream.conf"
  # shellcheck disable=SC2016 # expected file contents, nothing to expand
  printf '%s\n' 'set $vw_upstream http://vaultwarden-1-37-3;' > "${tmp}/upstream.expected"
  cmp -s "${tmp}/upstream.conf" "${tmp}/upstream.expected" || fail "upstream.conf rendering"
  flag_line > "${tmp}/flag.conf"
  printf '%s\n' "sub_filter '\"featureStates\":{' '\"featureStates\":{\"cipher-key-encryption\":true,';" > "${tmp}/flag.expected"
  cmp -s "${tmp}/flag.conf" "${tmp}/flag.expected" || fail "flag file rendering"
  if command -v openssl >/dev/null; then
    if openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes -config "${san_config}" \
         -keyout "${tmp}/vw.key" -out "${tmp}/vw.crt" >/dev/null 2>&1; then
      openssl x509 -in "${tmp}/vw.crt" -noout -text > "${tmp}/vw.txt"
      for v in "DNS:localhost" "IP Address:127.0.0.1" "CA:FALSE" "TLS Web Server Authentication"; do
        grep -q "${v}" "${tmp}/vw.txt" || fail "leaf shows ${v}"
      done
      openssl verify -CAfile "${tmp}/vw.crt" "${tmp}/vw.crt" >/dev/null 2>&1 || fail "leaf verifies as its own anchor"
    else
      fail "leaf generation from openssl-san.cnf"
    fi
  fi
  rm -rf "${tmp}"
  if [[ "${failures}" == 0 ]]; then echo "selftest OK"; else exit 1; fi
}

# --- dispatch ---------------------------------------------------------------------------------

cmd="${1:-}"
[[ $# -gt 0 ]] && shift
case "${cmd}" in
  ""|-h|--help) usage; exit 0 ;;
  selftest) cmd_selftest; exit $? ;;
esac
require_host "scripts/host/vaultwarden.sh ${cmd}"
require_docker
case "${cmd}" in
  up) cmd_up "$@" ;;
  down) cmd_down "$@" ;;
  status) cmd_status ;;
  cert) cmd_cert "$@" ;;
  flag) cmd_flag "$@" ;;
  snapshot) cmd_snapshot "$@" ;;
  restore) cmd_restore "$@" ;;
  keyed) cmd_keyed "$@" ;;
  *) usage; die "unknown command: ${cmd}" ;;
esac
