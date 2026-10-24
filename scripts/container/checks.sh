#!/usr/bin/env bash
# Every check that does not need macOS/Xcode. Runs in the devcontainer; when started on the
# host, it re-runs itself inside the container.
#
#   scripts/container/checks.sh             # blocking checks + advisory checks
#   scripts/container/checks.sh --strict    # advisory checks become blocking too
#   scripts/container/checks.sh --swift-format   # also run swift-format lint (advisory)
#
# Blocking (fail the run):
#   - openspec-changes: active OpenSpec changes pass `openspec validate --strict`
#   - shell-lint:       shellcheck on every *.sh in the repo
#   - plists:           Info.plist, *.entitlements, ExportOptions.plist parse as property lists
#   - xcschemes:        shared Xcode schemes are well-formed XML
# Advisory (reported; blocking only with --strict):
#   - openspec-specs:   main specs validate. Known debt: most upstream specs predate the
#                       "## Purpose / ## Requirements" structure, so this fails on main today.
#   - workflow-lint:    actionlint on .github/workflows. Known debt: the existing run: steps
#                       have shellcheck findings (unquoted $(ls ...) and similar).
#   - domain-typecheck: Prizm/Domain type-checks on Linux with only Foundation. This checks
#                       Architecture Rule 1 mechanically. Advisory until proven on this
#                       codebase, because Linux Foundation lacks a few Darwin-only APIs.
#   - swift-format:     only with --swift-format. The repo has no swift-format config, so the
#                       default style differs from the code and the output is noisy.
# The check_* functions are invoked indirectly through run(); shellcheck cannot see that.
# shellcheck disable=SC2329
set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

if ! in_container; then
  ensure_container
  exec_args=("scripts/container/checks.sh" "$@")
  cd "${PRIZM_REPO_ROOT}" && container_exec bash "${exec_args[@]}"
  exit $?
fi

strict=0
swift_format=0
for arg in "$@"; do
  case "${arg}" in
    --strict) strict=1 ;;
    --swift-format) swift_format=1 ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: ${arg}" ;;
  esac
done

cd "${PRIZM_REPO_ROOT}" || exit 1
declare -a results=()
blocking_failed=0

# run <name> <blocking|advisory> <command...>
run() {
  local name="$1" kind="$2"; shift 2
  [[ "${strict}" == 1 ]] && kind=blocking
  printf '\n──── %s (%s) ────\n' "${name}" "${kind}"
  if "$@"; then
    results+=("PASS  ${name}")
  elif [[ "${kind}" == blocking ]]; then
    results+=("FAIL  ${name}")
    blocking_failed=1
  else
    results+=("WARN  ${name} (advisory)")
  fi
}

check_openspec_changes() { openspec validate --changes --strict --no-interactive; }
check_openspec_specs()   { openspec validate --specs --no-interactive; }

check_shellcheck() {
  local files=()
  # LocalPackages/ is vendored third-party code (Argon2Swift) and is not linted here.
  mapfile -t files < <(git ls-files -co --exclude-standard '*.sh' ':!:LocalPackages/**')
  [[ ${#files[@]} -eq 0 ]] && { echo "no shell scripts"; return 0; }
  shellcheck -x "${files[@]}"
}

check_actionlint() { actionlint; }

check_plists() {
  local files=()
  mapfile -t files < <(git ls-files -co --exclude-standard '*.plist' '*.entitlements')
  python3 -I - "${files[@]}" <<'PY'
import plistlib, sys
bad = 0
for path in sys.argv[1:]:
    try:
        with open(path, "rb") as f:
            plistlib.load(f)
        print(f"ok   {path}")
    except Exception as e:  # report every file, then fail once
        print(f"BAD  {path}: {e}")
        bad = 1
sys.exit(bad)
PY
}

check_xcschemes() {
  local files=()
  mapfile -t files < <(git ls-files '*.xcscheme')
  [[ ${#files[@]} -eq 0 ]] && return 0
  xmllint --noout "${files[@]}" && echo "ok   ${#files[@]} scheme(s)"
}

# Mirrors the app target's Swift settings in project.pbxproj: Swift 6 language mode,
# SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, SWIFT_APPROACHABLE_CONCURRENCY = YES (the upcoming
# features it enables) and SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES.
check_domain_typecheck() {
  local files=()
  mapfile -t files < <(git ls-files 'Prizm/Domain/*.swift')
  swiftc -typecheck -module-name PrizmDomain -swift-version 6 \
    -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature DisableOutwardActorInference \
    "${files[@]}"
}

check_swift_format() {
  local files=()
  mapfile -t files < <(git ls-files 'Prizm/*.swift')
  swift format lint --parallel "${files[@]}"
}

run openspec-changes blocking check_openspec_changes
run shell-lint       blocking check_shellcheck
run plists           blocking check_plists
run xcschemes        blocking check_xcschemes
run openspec-specs   advisory check_openspec_specs
run workflow-lint    advisory check_actionlint
run domain-typecheck advisory check_domain_typecheck
[[ "${swift_format}" == 1 ]] && run swift-format advisory check_swift_format

printf '\n──── summary ────\n'
printf '%s\n' "${results[@]}"
printf '\nNot covered here (needs macOS + Xcode): build, unit tests, UI tests, signing.\n'
printf 'Run scripts/host/xcode.sh on the Mac, or scripts/build.sh for both.\n'
exit "${blocking_failed}"
