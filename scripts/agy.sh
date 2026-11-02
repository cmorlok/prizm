#!/usr/bin/env bash
# Host wrapper: runs the Antigravity CLI (agy) inside the Prizm devcontainer from the Mac's terminal.
#
#   scripts/agy.sh                    # interactive session in the current directory (inside the repo)
#   scripts/agy.sh -p "question"      # any agy arguments are passed through
#
# Tip: alias it, e.g.  alias pagy="$HOME/src/prizm/scripts/agy.sh"
# The container is started (or created) if needed; agy itself is installed by
# .devcontainer/post-create.sh. For a shell in the container use `scripts/claude.sh --shell`.
# See .devcontainer/README.md.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

in_container && die "Already inside the container; run 'agy' directly."

ensure_container
container_exec agy "$@"
