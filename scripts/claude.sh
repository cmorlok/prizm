#!/usr/bin/env bash
# Host wrapper: runs Claude Code inside the Prizm devcontainer from the Mac's terminal.
#
#   scripts/claude.sh                 # interactive session in the current directory (inside the repo)
#   scripts/claude.sh -p "question"   # any claude arguments are passed through
#   scripts/claude.sh --shell         # a shell in the container instead of claude
#
# Tip: alias it, e.g.  alias pclaude="$HOME/src/prizm/scripts/claude.sh"
# The container is started (or created) if needed. See .devcontainer/README.md.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

in_container && die "Already inside the container; run 'claude' directly."

ensure_container
if [[ "${1:-}" == "--shell" ]]; then
  shift
  container_exec zsh -l "$@"
else
  container_exec claude "$@"
fi
