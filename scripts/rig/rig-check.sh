#!/usr/bin/env bash
# Checks the Vaultwarden rig from the container: which server answers, the account file, TLS and the
# feature flag through the edge, and a login. Container only.
#
#   scripts/rig/rig-check.sh --version <1.37.3|1.37.4> [--env] [--edge] [--login]
#
#   (always)  alive OK <service>
#             server version=<GET /api/version> api-version=<config version> gitHash=<hash>
#   --env     the env file exists, has mode 600 and both keys:  env OK email=<email> mode=600
#   --edge    https://localhost:8443 through the pinned leaf, no system trust:
#             edge TLS OK upstream-version=<version> flag=<on|off>
#   --login   prelogin and login with the rig account:  login OK kdf=0 iterations=<n>
#
# "api-version" is /api/config's emulated Bitwarden API version (2026.6.0 on 1.37.3 and 1.37.4);
# the Vaultwarden version itself comes from GET /api/version. The password is never printed.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}"; }

version=""
want_env=0 want_edge=0 want_login=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 || die "--version needs a value" ;;
    --env) want_env=1; shift ;;
    --edge) want_edge=1; shift ;;
    --login) want_login=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[[ -n "${version}" ]] || { usage >&2; die "--version is required"; }

rig_init "${version}"
echo "alive OK ${RIG_SERVICE}"

server_version="$(rig_server_version)" || die "GET /api/version failed on ${RIG_SERVICE}."
config="$(rig_config)" || die "GET /api/config failed on ${RIG_SERVICE}."
api_version="$(printf '%s' "${config}" | jq -r '.version // "unknown"')"
git_hash="$(printf '%s' "${config}" | jq -r '.gitHash // "unknown"')"
echo "server version=${server_version} api-version=${api_version} gitHash=${git_hash}"
[[ "${server_version}" == "${version}" ]] \
  || die "${RIG_SERVICE} reports Vaultwarden ${server_version}, expected ${version}."

if (( want_env )); then
  [[ -f "${RIG_ENV_FILE}" ]] || die "dev-vault/.env does not exist."
  mode="$(stat -c %a "${RIG_ENV_FILE}")"
  [[ "${mode}" == 600 ]] || die "dev-vault/.env has mode ${mode}; run chmod 600 dev-vault/.env on the Mac."
  email="$(python3 -I "${RIG_TOKEN_FORM}" email "${RIG_ENV_FILE}")" \
    || die "dev-vault/.env has no usable PRIZM_RIG_EMAIL / PRIZM_RIG_PASSWORD."
  echo "env OK email=${email} mode=${mode}"
fi

if (( want_edge )); then
  cert="${PRIZM_REPO_ROOT}/dev-vault/certs/vw.crt"
  [[ -f "${cert}" ]] || die "dev-vault/certs/vw.crt is missing; run scripts/host/vaultwarden.sh cert on the Mac."
  edge_ip="$(getent hosts edge | awk '{print $1; exit}')"
  [[ -n "${edge_ip}" ]] || die "edge does not resolve. Start it on the Mac: scripts/host/vaultwarden.sh up ${version}"
  # The container's loopback is not the Mac's: reach edge by its compose address but verify the
  # certificate as "localhost", trusting only the pinned leaf (no system trust, RIG-03).
  edge_get() {
    curl -sS --fail --max-time 15 --cacert "${cert}" --resolve "localhost:8443:${edge_ip}" \
      "https://localhost:8443$1"
  }
  edge_version="$(edge_get /api/version | jq -r .)" \
    || die "https://localhost:8443/api/version failed through edge (TLS, upstream or certificate)."
  edge_config="$(edge_get /api/config)" || die "https://localhost:8443/api/config failed through edge."
  printf '%s' "${edge_config}" | jq -e . >/dev/null \
    || die "the /api/config body through edge is not valid JSON (flag injection broke it)."
  [[ "${edge_version}" == "${version}" ]] \
    || die "edge serves Vaultwarden ${edge_version}, expected ${version}; switch with scripts/host/vaultwarden.sh up ${version}."
  # grep -o prints one line per occurrence (the body is one line, so -c would undercount); grep
  # exits 1 for zero matches, which must not end the script.
  occurrences="$({ printf '%s' "${edge_config}" | grep -o 'cipher-key-encryption' || true; } | wc -l | tr -d ' ')"
  case "${occurrences}" in
    0) flag=off ;;
    1)
      # Present once as text is not enough: it must be the featureStates key, set to true.
      printf '%s' "${edge_config}" | jq -e '.featureStates["cipher-key-encryption"] == true' >/dev/null \
        || die "cipher-key-encryption occurs once but is not featureStates[\"cipher-key-encryption\"] == true."
      flag=on ;;
    *) die "cipher-key-encryption occurs ${occurrences} times in the /api/config body (expected 0 or 1)." ;;
  esac
  echo "edge TLS OK upstream-version=${edge_version} flag=${flag}"
fi

if (( want_login )); then
  rig_prelogin
  rig_login
  # Whatever the probes left in their state dir must hold no password, master key or server hash.
  shopt -s nullglob
  state_files=("${RIG_STATE_DIR}"/*)
  shopt -u nullglob
  if (( ${#state_files[@]} > 0 )); then
    python3 -I "${RIG_TOKEN_FORM}" absent "${RIG_ENV_FILE}" "${RIG_KDF_ITERATIONS}" "${state_files[@]}" \
      || die "a secret was found in the probe state directory."
  fi
  echo "login OK kdf=0 iterations=${RIG_KDF_ITERATIONS}"
fi
