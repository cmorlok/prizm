#!/usr/bin/env bash
# Shared helpers for the scripts in scripts/. Source it; do not execute it.

# Must match "runArgs": ["--name", ...] in .devcontainer/devcontainer.json.
PRIZM_CONTAINER="${PRIZM_CONTAINER:-prizm-dev}"
PRIZM_CONTAINER_USER="${PRIZM_CONTAINER_USER:-developer}"
# Must match "workspaceFolder" in .devcontainer/devcontainer.json.
PRIZM_CONTAINER_WORKSPACE="/workspaces/prizm"

# Physical path (-P), so it compares reliably with `pwd -P` in container_exec.
PRIZM_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

in_container() { [[ -f /.dockerenv || -n "${REMOTE_CONTAINERS:-}" ]] && [[ "$(uname -s)" == "Linux" ]]; }

require_host() {
  [[ "$(uname -s)" == "Darwin" ]] || die "$1 must run on the Mac host, not in the container."
}

# Ensures the devcontainer is running: starts a stopped container, or creates it with the
# Dev Containers CLI if it does not exist yet.
ensure_container() {
  command -v docker >/dev/null || die "docker not found on PATH."
  local state
  state="$(docker inspect -f '{{.State.Status}}' "${PRIZM_CONTAINER}" 2>/dev/null || true)"
  case "${state}" in
    running) return 0 ;;
    exited|created|paused)
      log "Starting container ${PRIZM_CONTAINER}"
      if [[ "${state}" == "paused" ]]; then docker unpause "${PRIZM_CONTAINER}" >/dev/null
      else docker start "${PRIZM_CONTAINER}" >/dev/null; fi ;;
    "")
      command -v devcontainer >/dev/null || die "Container ${PRIZM_CONTAINER} does not exist yet.
  Create it once with VS Code (\"Dev Containers: Reopen in Container\") or with the
  Dev Containers CLI:  npm install -g @devcontainers/cli && devcontainer up --workspace-folder ${PRIZM_REPO_ROOT}"
      log "Creating container ${PRIZM_CONTAINER} (first run builds the image; this takes a while)"
      devcontainer up --workspace-folder "${PRIZM_REPO_ROOT}" ;;
    *) die "Container ${PRIZM_CONTAINER} is in unexpected state '${state}'." ;;
  esac
}

# Runs a command in the container as the dev user. The caller's current directory is mapped from
# the host repo path to the container workspace (e.g. <repo>/Prizm/Domain on the host becomes
# /workspaces/prizm/Prizm/Domain); outside the repo it falls back to the workspace root, because
# nothing else from the host is mounted.
container_exec() {
  local here workdir
  here="$(pwd -P)"
  case "${here}" in
    "${PRIZM_REPO_ROOT}"|"${PRIZM_REPO_ROOT}"/*)
      workdir="${PRIZM_CONTAINER_WORKSPACE}${here#"${PRIZM_REPO_ROOT}"}" ;;
    *) workdir="${PRIZM_CONTAINER_WORKSPACE}" ;;
  esac
  local tty_flags=(-i)
  [[ -t 0 && -t 1 ]] && tty_flags=(-it)
  local env_flags=(-e "TERM=${TERM:-xterm-256color}")
  [[ -n "${COLORTERM:-}" ]] && env_flags+=(-e "COLORTERM=${COLORTERM}")
  # Forward an API key only if the host has one; otherwise the container's own login is used.
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && env_flags+=(-e ANTHROPIC_API_KEY)
  docker exec "${tty_flags[@]}" "${env_flags[@]}" -u "${PRIZM_CONTAINER_USER}" -w "${workdir}" \
    "${PRIZM_CONTAINER}" "$@"
}
