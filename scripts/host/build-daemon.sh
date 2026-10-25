#!/usr/bin/env bash
# Runs Xcode builds on the Mac on request from the devcontainer. Start it in a Mac terminal and
# leave it running; inside the container, scripts/build.sh and scripts/container/host-build.sh
# then hand the Xcode part to it.
#
#   scripts/host/build-daemon.sh            # serve requests until Ctrl-C
#
# It runs only the commands of scripts/host/xcode.sh (build, test, test-ui, test-all, release,
# ci, clean), one at a time, in request order. Protocol: scripts/lib/build-bridge.sh.
# Testing hook: PRIZM_BRIDGE_RUNNER replaces scripts/host/xcode.sh, so the protocol can be
# exercised without Xcode (also on Linux).
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/build-bridge.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/build-bridge.sh"

case "${1:-}" in -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;; esac

runner="${PRIZM_BRIDGE_RUNNER:-${PRIZM_REPO_ROOT}/scripts/host/xcode.sh}"
[[ -n "${PRIZM_BRIDGE_RUNNER:-}" ]] || require_host "scripts/host/build-daemon.sh"

mkdir -p "${PRIZM_BRIDGE_DIR}"
cd "${PRIZM_BRIDGE_DIR}" || die "cannot enter ${PRIZM_BRIDGE_DIR}"

if [[ -f daemon.pid ]] && kill -0 "$(cat daemon.pid)" 2>/dev/null; then
  die "a build daemon is already running (PID $(cat daemon.pid))."
fi
bridge_write_atomic daemon.pid "$$"

# A build that was running when a previous daemon died would leave its client waiting forever.
for stale in *.running; do
  [[ -e "${stale}" ]] || continue
  id="${stale%.running}"
  echo "build daemon restarted; this build was aborted" >>"${id}.log"
  bridge_write_atomic "${id}.exit" 125
  rm -f "${stale}"
done
# Old logs and leftovers; requests are kept, they are still waiting.
find . -maxdepth 1 -type f ! -name '*.request' ! -name 'daemon.*' -mtime +7 -delete 2>/dev/null

build_pid=""
current_id=""
shutdown() {
  if [[ -n "${build_pid}" ]]; then
    kill -TERM -- "-${build_pid}" 2>/dev/null
    # Tell the waiting client now instead of letting it wait for a stale heartbeat.
    echo "build daemon stopped; this build was aborted" >>"${current_id}.log"
    bridge_write_atomic "${current_id}.exit" 125
    rm -f "${current_id}.running" "${current_id}.cancel"
  fi
  rm -f daemon.pid daemon.heartbeat
  log "build daemon stopped"
  exit 0
}
trap shutdown INT TERM

# Runs one request. The build gets its own process group (set -m), so a cancel or Ctrl-C stops
# xcodebuild and everything it started, not just the pipeline's first process.
run_request() {
  local id="$1" cmd code
  mv -f "${id}.request" "${id}.running" 2>/dev/null || return 0  # gone: client gave up
  cmd="$(head -n 1 "${id}.running" | tr -d '[:space:]')"
  : >"${id}.log"

  if ! bridge_command_allowed "${cmd}"; then
    echo "build daemon: refused command '${cmd}'; allowed: ${PRIZM_BRIDGE_COMMANDS}" | tee -a "${id}.log"
    bridge_write_atomic "${id}.exit" 2
    rm -f "${id}.running"
    return 0
  fi

  log "${id}: ${cmd}"
  set -m
  ( cd "${PRIZM_REPO_ROOT}" && "${runner}" "${cmd}" 2>&1 | tee -a "${PRIZM_BRIDGE_DIR}/${id}.log" ) &
  build_pid=$!
  current_id="${id}"
  set +m

  while kill -0 "${build_pid}" 2>/dev/null; do
    bridge_write_atomic daemon.heartbeat "$(date +%s)"
    if [[ -e "${id}.cancel" ]]; then
      log "${id}: cancelled by the client"
      kill -TERM -- "-${build_pid}" 2>/dev/null
    fi
    sleep 1
  done
  wait "${build_pid}"
  code=$?
  build_pid=""
  [[ -e "${id}.cancel" ]] && { echo "build cancelled" >>"${id}.log"; code=130; }

  bridge_write_atomic "${id}.exit" "${code}"
  rm -f "${id}.running" "${id}.cancel"
  log "${id}: exit ${code}"
}

log "build daemon watching ${PRIZM_BRIDGE_DIR} (Ctrl-C to stop)"
while true; do
  bridge_write_atomic daemon.heartbeat "$(date +%s)"
  # Request IDs start with a UTC timestamp and globs expand sorted, so the first match is the
  # oldest request.
  next=""
  for request in *.request; do
    [[ -e "${request}" ]] && { next="${request}"; break; }
  done
  if [[ -n "${next}" ]]; then
    run_request "${next%.request}"
  else
    sleep 1
  fi
done
