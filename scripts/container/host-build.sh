#!/usr/bin/env bash
# Runs one scripts/host/xcode.sh command on the Mac from inside the devcontainer, through the
# host build daemon, and streams its output. Exits with the build's exit code.
#
#   scripts/container/host-build.sh test        # build + unit tests on the Mac
#   scripts/container/host-build.sh build       # also: test-ui, test-all, release, ci, clean
#
# Needs scripts/host/build-daemon.sh running in a Mac terminal. Ctrl-C cancels the build.
# Environment: PRIZM_BRIDGE_TIMEOUT (seconds, default 7200) limits how long it waits.
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/build-bridge.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/build-bridge.sh"

cmd="${1:-}"
case "${cmd}" in ""|-h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;; esac
bridge_command_allowed "${cmd}" || die "unknown command: ${cmd} (allowed: ${PRIZM_BRIDGE_COMMANDS})"
timeout="${PRIZM_BRIDGE_TIMEOUT:-7200}"

daemon_hint="Start it in a Mac terminal, in the repo:  scripts/host/build-daemon.sh"
heartbeat_age() {
  local beat
  beat="$(cat "${PRIZM_BRIDGE_DIR}/daemon.heartbeat" 2>/dev/null)" || { echo 999999; return; }
  [[ "${beat}" =~ ^[0-9]+$ ]] || { echo 999999; return; }
  echo $(( $(date +%s) - beat ))
}
(( $(heartbeat_age) <= PRIZM_BRIDGE_STALE_AFTER )) || die "the host build daemon is not running.
  ${daemon_hint}"

id="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
base="${PRIZM_BRIDGE_DIR}/${id}"
bridge_write_atomic "${base}.request" "${cmd}"
log "Requested '${cmd}' from the host build daemon (${id})"

cancelled=0
# Invoked through the trap below; shellcheck cannot see that.
# shellcheck disable=SC2329
on_interrupt() {
  cancelled=1
  # Not started yet: withdraw the request. The rename is atomic, so it either beats the daemon's
  # own rename (build never starts) or fails (build is running and must be cancelled).
  if mv "${base}.request" "${base}.withdrawn" 2>/dev/null; then
    rm -f "${base}.withdrawn"
    die "cancelled before the build started"
  fi
  : >"${base}.cancel"
  warn "cancelling the build on the host..."
}
trap on_interrupt INT TERM

# Streams the log by byte offset until the exit file appears. The daemon writes the exit file
# only after the log is complete, so the final read gets every line.
offset=0
started="$(date +%s)"
stream_new_output() {
  local size
  [[ -f "${base}.log" ]] || return 0
  size="$(stat -c %s "${base}.log" 2>/dev/null || echo 0)"
  if (( size > offset )); then
    tail -c "+$(( offset + 1 ))" "${base}.log" | head -c "$(( size - offset ))"
    offset="${size}"
  fi
}

while [[ ! -e "${base}.exit" ]]; do
  stream_new_output
  if (( $(heartbeat_age) > 2 * PRIZM_BRIDGE_STALE_AFTER )); then
    die "the host build daemon stopped while handling ${id}. ${daemon_hint}"
  fi
  if (( $(date +%s) - started > timeout )); then
    : >"${base}.cancel"
    die "no result after ${timeout}s; asked the daemon to cancel ${id}."
  fi
  sleep 0.5
done
stream_new_output

code="$(head -n 1 "${base}.exit" | tr -d '[:space:]')"
[[ "${code}" =~ ^[0-9]+$ ]] || code=1
# Keep the log for later reading; the daemon prunes logs after 7 days.
rm -f "${base}.exit"
(( cancelled )) && warn "build cancelled"
log "Host build '${cmd}' finished with exit ${code}; log: build/host-bridge/${id}.log"
exit "${code}"
