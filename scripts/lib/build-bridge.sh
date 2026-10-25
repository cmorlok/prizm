#!/usr/bin/env bash
# Shared definitions for the host build bridge: scripts/host/build-daemon.sh (Mac) runs the Xcode
# part of the build on request from the container (scripts/container/host-build.sh). Source it
# after common.sh; do not execute it.
#
# Protocol, all files in PRIZM_BRIDGE_DIR (inside the repo, so both sides see the same files):
#   daemon.pid        PID of the running daemon (host).
#   daemon.heartbeat  epoch seconds, rewritten by the daemon every poll.
#   <id>.request      one line: an xcode.sh command. Written by the client, renamed into place
#                     so the daemon never sees a partial file.
#   <id>.running      the daemon renames the request to this when it starts the build.
#   <id>.log          build output (stdout and stderr), written while the build runs.
#   <id>.exit         exit code, renamed into place after the log is complete.
#   <id>.cancel       written by the client to ask the daemon to stop the build.
# Polling instead of file events: inotify/FSEvents are unreliable across Docker bind mounts.

# The variables below are used by the scripts that source this file.
# shellcheck disable=SC2034

PRIZM_BRIDGE_DIR="${PRIZM_REPO_ROOT}/build/host-bridge"

# The only commands the daemon runs. Keep in sync with the cases in scripts/host/xcode.sh.
# The container must not be able to make the host run anything else.
PRIZM_BRIDGE_COMMANDS="build test test-ui test-all release ci clean"

# Heartbeat age, in seconds, after which the client treats the daemon as not running.
PRIZM_BRIDGE_STALE_AFTER=30

bridge_command_allowed() {
  local cmd
  for cmd in ${PRIZM_BRIDGE_COMMANDS}; do
    [[ "$1" == "${cmd}" ]] && return 0
  done
  return 1
}

# Writes $2 to file $1 atomically (temp file + rename in the same directory).
bridge_write_atomic() {
  local tmp="$1.tmp.$$"
  printf '%s\n' "$2" >"${tmp}" && mv -f "${tmp}" "$1"
}
