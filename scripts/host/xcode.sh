#!/usr/bin/env bash
# The part of the build that needs macOS and Xcode. Run it on the Mac, not in the container.
#
#   scripts/host/xcode.sh build        # Debug build of the app
#   scripts/host/xcode.sh test         # unit + integration tests (PrizmTests)
#   scripts/host/xcode.sh test-ui      # UI journeys (PrizmUITests scheme; drives the real app)
#   scripts/host/xcode.sh test-all     # test + test-ui
#   scripts/host/xcode.sh release      # Release build signed with your local team (not notarized)
#   scripts/host/xcode.sh clean
#
# Uses Prizm/LocalConfig.xcconfig for signing (DEVELOPMENT_TEAM; see DEVELOPMENT.md).
# Build products go to build/DerivedData (git-ignored). Output is piped through xcbeautify or
# xcpretty when either is installed. -allowProvisioningUpdates lets automatic signing create
# the development profile from the command line, as the Xcode GUI does (needs your Apple ID in
# Xcode → Settings → Accounts).
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

case "${1:-}" in ""|-h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;; esac
require_host "scripts/host/xcode.sh"
command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

cd "${PRIZM_REPO_ROOT}"

project="Prizm/Prizm.xcodeproj"
derived="build/DerivedData"
local_config="Prizm/LocalConfig.xcconfig"

check_local_config() {
  [[ -f "${local_config}" ]] || die "${local_config} is missing.
  cp ${local_config}.template ${local_config}   then set DEVELOPMENT_TEAM (see DEVELOPMENT.md)."
  grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}[[:space:]]*$' "${local_config}" \
    || die "DEVELOPMENT_TEAM in ${local_config} is not set to a 10-character Team ID."
}

pretty() {
  if command -v xcbeautify >/dev/null; then xcbeautify
  elif command -v xcpretty >/dev/null; then xcpretty
  else cat; fi
}

# xcb <scheme> <configuration> <action...> [extra args]
xcb() {
  local scheme="$1" configuration="$2"; shift 2
  log "xcodebuild ${scheme} (${configuration}): $*"
  set -o pipefail
  xcodebuild -project "${project}" -scheme "${scheme}" -configuration "${configuration}" \
    -destination "platform=macOS" -derivedDataPath "${derived}" \
    -allowProvisioningUpdates "$@" | pretty
}

cmd="${1:-}"
case "${cmd}" in
  build)    check_local_config; xcb Prizm Debug build ;;
  test)     check_local_config; xcb Prizm Debug test -only-testing:PrizmTests ;;
  test-ui)  check_local_config; xcb PrizmUITests Debug test ;;
  test-all) check_local_config
            xcb Prizm Debug test -only-testing:PrizmTests
            xcb PrizmUITests Debug test ;;
  release)  check_local_config; xcb Prizm Release build
            log "Built ${derived}/Build/Products/Release/Prizm.app (signed with your team, not notarized)" ;;
  clean)    rm -rf "${derived}"; log "Removed ${derived}" ;;
  *) die "unknown command: ${cmd} (try --help)" ;;
esac
