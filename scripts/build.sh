#!/usr/bin/env bash
# Full local pipeline: container checks first (fast, no Xcode), then the Xcode part on the Mac.
# Works from the Mac and from inside the devcontainer. In the container, the Xcode part is handed
# to scripts/host/build-daemon.sh, which must be running in a Mac terminal.
#
#   scripts/build.sh                  # checks, then build + unit tests
#   scripts/build.sh test-all         # checks, then build + unit + UI tests
#   scripts/build.sh --checks-only    # only the container checks
#   scripts/build.sh --host-only test # skip the container checks
#   scripts/build.sh --strict ...     # advisory container checks become blocking
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if ! in_container; then
  require_host "scripts/build.sh"
fi

run_checks=1
run_host=1
check_args=()
host_cmd="test"
for arg in "$@"; do
  case "${arg}" in
    --checks-only) run_host=0 ;;
    --host-only)   run_checks=0 ;;
    --strict)      check_args+=(--strict) ;;
    -h|--help)     sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)            die "unknown option: ${arg}" ;;
    *)             host_cmd="${arg}" ;;
  esac
done

if [[ "${run_checks}" == 1 ]]; then
  log "Container checks (${PRIZM_CONTAINER})"
  # ${arr[@]+...} keeps an empty array from tripping `set -u` in macOS's bash 3.2.
  "${PRIZM_REPO_ROOT}/scripts/container/checks.sh" ${check_args[@]+"${check_args[@]}"}
fi

if [[ "${run_host}" == 1 ]]; then
  # `test` also builds, so a separate build step is only needed for build-only commands.
  log "Xcode on host: ${host_cmd}"
  if in_container; then
    "${PRIZM_REPO_ROOT}/scripts/container/host-build.sh" "${host_cmd}"
  else
    "${PRIZM_REPO_ROOT}/scripts/host/xcode.sh" "${host_cmd}"
  fi
fi
