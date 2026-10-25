#!/usr/bin/env bash
# The part of the build that needs macOS and Xcode. Run it on the Mac, not in the container.
#
#   scripts/host/xcode.sh build        # Debug build of the app
#   scripts/host/xcode.sh test         # unit + integration tests (PrizmTests)
#   scripts/host/xcode.sh test-ui      # UI journeys (PrizmUITests scheme; drives the real app)
#   scripts/host/xcode.sh test-all     # test + test-ui
#   scripts/host/xcode.sh release      # Release build signed with your local team (not notarized)
#   scripts/host/xcode.sh ci           # what CI runs: project checks, unsigned build + tests
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

case "${1:-}" in ""|-h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;; esac
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

# Mirrors .github/workflows/ci.yml (keep in sync): the project checks, then an unsigned Debug build
# and the unsigned unit tests with Address Sanitizer. Command-line settings clear your personal
# DEVELOPMENT_TEAM and PRIZM_BUNDLE_IDENTIFIER, so the build sees the template defaults like CI.
# Products go to build/DerivedData-ci, so your signed build products stay untouched.
ci_run() {
  local ci_derived="build/DerivedData-ci"
  local unsigned=(CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
                  DEVELOPMENT_TEAM="" PRIZM_BUNDLE_IDENTIFIER="")
  [[ -f "${local_config}" ]] || die "${local_config} is missing.
  cp ${local_config}.template ${local_config}   (CI does the same)"

  log "ci: no Team ID committed in the project file"
  if grep -nE 'DEVELOPMENT_TEAM = "?[A-Za-z0-9]+"?;' "${project}/project.pbxproj"; then
    die "DEVELOPMENT_TEAM is set in project.pbxproj. Set it in ${local_config} instead."
  fi

  log "ci: unsigned Debug build"
  set -o pipefail
  xcodebuild -project "${project}" -scheme Prizm -configuration Debug \
    -derivedDataPath "${ci_derived}" "${unsigned[@]}" build | pretty

  log "ci: the built app has a bundle identifier"
  local plist="${ci_derived}/Build/Products/Debug/Prizm.app/Contents/Info.plist" id
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || die "The built app has no CFBundleIdentifier. Set PRODUCT_BUNDLE_IDENTIFIER for the Prizm target."
  log "CFBundleIdentifier: ${id}"

  log "ci: unsigned unit tests with Address Sanitizer"
  xcodebuild test -project "${project}" -scheme Prizm -destination "platform=macOS" \
    -enableAddressSanitizer YES -derivedDataPath "${ci_derived}" "${unsigned[@]}" | pretty
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
  ci)       ci_run ;;
  clean)    rm -rf "${derived}" build/DerivedData-ci; log "Removed ${derived} and build/DerivedData-ci" ;;
  *) die "unknown command: ${cmd} (try --help)" ;;
esac
