#!/usr/bin/env bash
# Container-side probe library for the Vaultwarden rig. Source it; do not execute it.
#
#   source scripts/rig/lib.sh
#   rig_init 1.37.3                      # preflight: service resolves, env keys exist, /alive answers
#   rig_api GET "/api/sync?excludeDomains=true" "${RIG_STATE_DIR}/sync.json"   # prints the HTTP status
#
# The probes run in the container only: they reach Vaultwarden over the compose network by service
# name (http://vaultwarden-1-37-X, plain HTTP, no TLS trust needed) and talk to the throwaway rig
# account whose credentials are in dev-vault/.env (keys PRIZM_RIG_EMAIL, PRIZM_RIG_PASSWORD).
# See .devcontainer/rig/RUNBOOK.md.
#
# Secret handling (threat T-01-06): the master password and the server hash exist only inside
# token-form.py and a shell variable that is piped into curl's stdin; the access token lives only in
# a mode-600 file and in mode-600 header files passed with `-H @file`. argv is visible to every
# process via `ps`, so no secret is ever an argument. No function prints a token, a password, a
# hash or an /identity response body, and nothing here enables shell tracing or verbose curl.
#
# Login rate limit (T-01-11): Vaultwarden allows a burst of 10 token requests, then one per 60 s
# per client IP. The token is cached per version and a new login happens only when it has expired
# or the server answers 401.
#
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Prizm's identity on the wire (App/Config.swift, PrizmAPIClientImpl.baseRequest). The client
# version must be >= 2024.12.0 or Vaultwarden hides SSH key items (type 5) from /api/sync.
RIG_USER_AGENT="Prizm/1.5.0 (rig probe)"
RIG_CLIENT_VERSION="2024.12.0"

RIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RIG_TOKEN_FORM="${RIG_LIB_DIR}/token-form.py"

# rig_init <version>: validates the version and sets RIG_VERSION, RIG_SERVICE, RIG_BASE,
# RIG_STATE_DIR, RIG_EVIDENCE_DIR and RIG_ENV_FILE. Dies with the exact Mac command when the
# service does not resolve.
rig_init() {
  in_container || die "scripts/rig/* run in the container: they reach http://vaultwarden-1-37-X on the compose network."
  local version="${1:-}"
  case "${version}" in
    1.37.3|1.37.4) ;;
    *) die "unsupported Vaultwarden version '${version}' (use 1.37.3 or 1.37.4)." ;;
  esac
  RIG_VERSION="${version}"
  RIG_SERVICE="vaultwarden-${version//./-}"
  RIG_BASE="http://${RIG_SERVICE}"
  RIG_STATE_DIR="${TMPDIR:-/tmp}/prizm-rig-$(id -u)"
  RIG_EVIDENCE_DIR="${PRIZM_REPO_ROOT}/dev-vault/evidence"
  RIG_ENV_FILE="${PRIZM_REPO_ROOT}/dev-vault/.env"
  RIG_DEVICE_ID_FILE="${PRIZM_REPO_ROOT}/dev-vault/.probe-device-id"
  RIG_KDF_ITERATIONS=""

  ( umask 077; mkdir -p "${RIG_STATE_DIR}" )
  chmod 700 "${RIG_STATE_DIR}"

  getent hosts "${RIG_SERVICE}" >/dev/null \
    || die "${RIG_SERVICE} does not resolve. Start it on the Mac: scripts/host/vaultwarden.sh up ${version}
  (If prizm-dev was created before the compose conversion, recreate it from compose first; see .devcontainer/README.md.)"

  local key
  for key in PRIZM_RIG_EMAIL PRIZM_RIG_PASSWORD; do
    # grep -q reads the file but prints nothing: only the key's presence is checked here.
    if [[ ! -f "${RIG_ENV_FILE}" ]] || ! grep -q "^${key}=" "${RIG_ENV_FILE}"; then
      die "add PRIZM_RIG_EMAIL and PRIZM_RIG_PASSWORD to dev-vault/.env (plan 03 Task 2 step 8); ${key} is missing."
    fi
  done

  local code
  code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "${RIG_BASE}/alive")" \
    || die "${RIG_BASE}/alive is not reachable."
  [[ "${code}" == 200 ]] || die "${RIG_BASE}/alive answered HTTP ${code}."
}

# rig_headers <file>: Prizm's identification headers in a mode-600 file, for `-H @file`.
rig_headers() {
  local file="$1"
  (
    umask 077
    printf '%s\n' \
      "User-Agent: ${RIG_USER_AGENT}" \
      'Accept: application/json' \
      'Device-Type: 7' \
      'Bitwarden-Client-Name: desktop' \
      "Bitwarden-Client-Version: ${RIG_CLIENT_VERSION}" > "${file}"
  )
}

# rig_prelogin: asks the server for the account's KDF and exports RIG_KDF_ITERATIONS. Fails closed
# unless the KDF is PBKDF2-SHA256 (kdf 0). Prelogin for an unknown email returns pseudo-random
# settings, so success does not prove that the account exists.
rig_prelogin() {
  local email hdr out kdf iterations code
  email="$(python3 -I "${RIG_TOKEN_FORM}" email "${RIG_ENV_FILE}")" || die "cannot read the rig account email."
  hdr="$(mktemp "${RIG_STATE_DIR}/hdr.XXXXXX")"
  out="$(mktemp "${RIG_STATE_DIR}/prelogin.XXXXXX")"
  rig_headers "${hdr}"
  # /api/accounts/prelogin no longer exists on Vaultwarden 1.37.4 (Lane A fix/004).
  code="$(jq -cn --arg email "${email}" '{email: $email}' \
    | curl -sS --max-time 30 -o "${out}" -w '%{http_code}' -H @"${hdr}" \
        -H 'Content-Type: application/json' --data-binary @- \
        "${RIG_BASE}/identity/accounts/prelogin/password")" || code="000"
  rm -f "${hdr}"
  if [[ "${code}" != 200 ]]; then
    rm -f "${out}"
    die "prelogin answered HTTP ${code}."
  fi
  kdf="$(jq -r '.kdf // empty' "${out}" 2>/dev/null || true)"
  iterations="$(jq -r '.kdfIterations // empty' "${out}" 2>/dev/null || true)"
  rm -f "${out}"
  [[ "${kdf}" == 0 ]] || die "unsupported KDF '${kdf:-unknown}' (probes handle PBKDF2-SHA256 only); register the rig account with the default KDF."
  [[ "${iterations}" =~ ^[0-9]+$ ]] || die "prelogin returned no usable iteration count."
  RIG_KDF_ITERATIONS="${iterations}"
  export RIG_KDF_ITERATIONS
}

rig_token_file() { printf '%s/%s.token' "${RIG_STATE_DIR}" "${RIG_VERSION}"; }

# rig_login: logs in and caches the access token. Prints only a status line on failure.
# All of its messages go to stderr because rig_api's stdout is the HTTP status code.
rig_login() {
  [[ -n "${RIG_KDF_ITERATIONS}" ]] || rig_prelogin

  if [[ ! -f "${RIG_DEVICE_ID_FILE}" ]]; then
    ( umask 077; python3 -I -c 'import uuid; print(uuid.uuid4())' > "${RIG_DEVICE_ID_FILE}" )
  fi
  local device_id
  device_id="$(tr -d '[:space:]' < "${RIG_DEVICE_ID_FILE}")"

  local hdr resp code form
  hdr="$(mktemp "${RIG_STATE_DIR}/hdr.XXXXXX")"
  resp="$(mktemp "${RIG_STATE_DIR}/identity.XXXXXX")"
  rig_headers "${hdr}"

  # The form holds the server hash: it stays in this shell variable and goes to curl on stdin.
  form="$(python3 -I "${RIG_TOKEN_FORM}" form "${RIG_ENV_FILE}" "${RIG_KDF_ITERATIONS}" "${device_id}")" \
    || { rm -f "${hdr}" "${resp}"; die "could not build the token form."; }
  code="$(printf '%s' "${form}" \
    | curl -sS --max-time 30 -o "${resp}" -w '%{http_code}' -H @"${hdr}" \
        -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @- \
        "${RIG_BASE}/identity/connect/token")" || code="000"
  form=""
  rm -f "${hdr}"

  if [[ "${code}" != 200 ]]; then
    local reason
    # Vaultwarden leaves error and error_description empty on a wrong password and puts its fixed
    # message (for example "Username or password is incorrect") in errorModel.message; nothing else
    # of the body is shown.
    reason="$(jq -r '[.error, .error_description, .errorModel.message] | map(select(. != null and . != "")) | join(": ")' "${resp}" 2>/dev/null || true)"
    rm -f "${resp}"
    if [[ "${code}" == 429 ]]; then
      warn "login rate limit: wait 60 s before the next login (burst of 10, then one per minute)."
    fi
    die "login answered HTTP ${code}${reason:+ (${reason})}."
  fi

  local token expires_in token_file
  token="$(jq -r '.access_token // empty' "${resp}")"
  expires_in="$(jq -r '.expires_in // empty' "${resp}")"
  rm -f "${resp}"
  [[ -n "${token}" && "${expires_in}" =~ ^[0-9]+$ ]] || die "login answer had no access token."
  token_file="$(rig_token_file)"
  ( umask 077; printf '%s\n%s\n' "$(( $(date +%s) + expires_in - 60 ))" "${token}" > "${token_file}" )
  token=""
}

# rig_token_valid: a cached, unexpired token exists.
rig_token_valid() {
  local token_file expiry
  token_file="$(rig_token_file)"
  [[ -f "${token_file}" ]] || return 1
  expiry="$(sed -n 1p "${token_file}")"
  [[ "${expiry}" =~ ^[0-9]+$ ]] && (( expiry > $(date +%s) ))
}

# rig_api <METHOD> <PATH> <OUT_FILE> [<BODY_FILE>]: authenticated request, prints the HTTP status.
# It usually runs inside $(...), where a die only ends that subshell: callers write
# `status="$(rig_api ...)" || exit 1`.
# PATH starts with /api. The body is sent as application/json only when BODY_FILE is given: Prizm
# sends no Content-Type for restore and soft delete, and Vaultwarden answers 400 to a mismatch.
# On 401 the cached token is dropped, one new login happens and the request is retried once.
rig_api() {
  local method="$1" path="$2" out="$3" body="${4:-}"
  local attempt code hdr
  for attempt in 1 2; do
    rig_token_valid || rig_login
    hdr="$(mktemp "${RIG_STATE_DIR}/hdr.XXXXXX")"
    rig_headers "${hdr}"
    ( umask 077; printf 'Authorization: Bearer %s\n' "$(sed -n 2p "$(rig_token_file)")" >> "${hdr}" )

    local args=(-sS --max-time 60 -o "${out}" -w '%{http_code}' -H @"${hdr}")
    [[ "${method}" == GET ]] || args+=(-X "${method}")
    if [[ -n "${body}" ]]; then
      args+=(-H 'Content-Type: application/json' --data-binary @"${body}")
    fi
    code="$( umask 077; curl "${args[@]}" "${RIG_BASE}${path}")" || code="000"
    rm -f "${hdr}"

    if [[ "${code}" == 401 && "${attempt}" == 1 ]]; then
      rm -f "$(rig_token_file)"
      continue
    fi
    break
  done
  printf '%s\n' "${code}"
}

# rig_server_version: the Vaultwarden version, from the unauthenticated GET /api/version
# (a JSON string). /api/config's "version" is only the emulated Bitwarden API version.
rig_server_version() {
  curl -sS --max-time 10 "${RIG_BASE}/api/version" | jq -r .
}

# rig_config: GET /api/config (unauthenticated) to stdout.
rig_config() {
  curl -sS --max-time 10 "${RIG_BASE}/api/config"
}

# rig_evidence <row> <message>: appends "<UTC time> <version> <message>" to
# dev-vault/evidence/<row>-<version>.log (git-ignored).
rig_evidence() {
  local row="$1" message="$2"
  [[ "${row}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid evidence row name '${row}'."
  mkdir -p "${RIG_EVIDENCE_DIR}"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RIG_VERSION}" "${message}" \
    >> "${RIG_EVIDENCE_DIR}/${row}-${RIG_VERSION}.log"
}
