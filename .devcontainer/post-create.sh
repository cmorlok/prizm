#!/usr/bin/env bash
# Runs once inside the container after creation (devcontainer.json "postCreateCommand").
#
# Sets up the per-project Claude Code tooling. Everything it writes is git-ignored:
#   - OpenSpec slash commands and skills  -> .claude/ (via `openspec init --tools claude`)
#   - GSD commands, agents and hooks      -> .claude/ (via the GSD installer, --local)
#   - .planning/ (GSD's working files)    -> excluded in .git/info/exclude, never committed
# It finishes by checking that no tracked file was modified.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

log() { printf '\n==> %s\n' "$*"; }

: "${OPENSPEC_VERSION:?set by the Dockerfile}"
: "${GSD_VERSION:?set by the Dockerfile}"

tracked_before="$(git status --porcelain --untracked-files=no)"

# OpenSpec's default "core" profile lacks /opsx:new and /opsx:verify, which CLAUDE.md uses.
# The "custom" profile with every workflow installs the full command set. This global config
# lives in the container user's home (not the host's).
log "Configuring OpenSpec ${OPENSPEC_VERSION} (custom profile, all workflows, telemetry off)"
openspec_config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/openspec"
mkdir -p "${openspec_config_dir}"
cat > "${openspec_config_dir}/config.json" <<'JSON'
{
  "profile": "custom",
  "delivery": "both",
  "workflows": ["propose", "explore", "new", "continue", "apply", "update", "ff", "sync",
                "archive", "bulk-archive", "verify", "onboard"],
  "telemetry": { "enabled": false }
}
JSON

# openspec/ already exists, so init runs in "extend" mode: it keeps openspec/config.yaml and only
# generates the Claude integration files. stdin is closed so it can never wait for a prompt.
log "Generating OpenSpec commands for Claude Code"
openspec init --tools claude --profile custom --no-animation < /dev/null

log "Installing GSD (@opengsd/gsd-core@${GSD_VERSION}) into this project's .claude/"
npx --yes "@opengsd/gsd-core@${GSD_VERSION}" --claude --local --relative-includes < /dev/null

# Keep GSD's planning files out of every commit and PR without touching the tracked .gitignore.
exclude_file="$(git rev-parse --git-path info/exclude)"
if ! grep -qxF '.planning/' "${exclude_file}" 2>/dev/null; then
  log "Excluding .planning/ locally (${exclude_file})"
  printf '\n# GSD working files (local only)\n.planning/\n' >> "${exclude_file}"
fi

tracked_after="$(git status --porcelain --untracked-files=no)"
if [[ "${tracked_after}" != "${tracked_before}" ]]; then
  log "WARNING: setup modified tracked files. Review before committing:"
  diff <(printf '%s\n' "${tracked_before}") <(printf '%s\n' "${tracked_after}") || true
  exit 1
fi

log "Done"
printf '  claude   %s\n' "$(claude --version 2>/dev/null || echo 'not found')"
printf '  openspec %s\n' "$(openspec --version)"
printf '  gsd      %s (project-local)\n' "${GSD_VERSION}"
printf '  swift    %s\n' "$(swift --version 2>/dev/null | head -1)"
cat <<'EOF'

Next steps:
  - Run `claude` once and log in (stored in ~/.claude, which lives in the prizm-dev-home volume).
  - Container checks: scripts/container/checks.sh
  - Xcode build/test: run scripts/host/xcode.sh on the Mac (not in this container).
EOF
