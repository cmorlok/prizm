#!/usr/bin/env bash
# Secret-free summary of the rig account's /api/sync, and checks of the fixture set. Container only
# (except --selftest, which is offline).
#
#   scripts/rig/sync-summary.sh --version <1.37.3|1.37.4> [--expect controls|fixture|fixture-unkeyed]
#   scripts/rig/sync-summary.sh --selftest
#
# Prints one row per cipher (role, type, keyed, counts; never an EncString), then
# "profile key prefix=<first 2 chars>", "email=<profile email>" and "ciphers total=<m> keyed=<n>".
# With --expect it ends in "expect <mode> OK", or exits 1 with "expect <mode> FAILED: <items>":
#   controls         presence only: control and twin are both assigned (unambiguously) and unkeyed.
#                    Other ciphers are allowed, so it holds right after authoring the controls and
#                    on the finished six-item fixture.
#   fixture          controls, plus exactly one each of passkey-login (keyed, passkey, password
#                    history, 2+ URIs all with checksum, attachment), archived (keyed), ssh (keyed,
#                    private key, public key and fingerprint) and org-login (keyed); no extra
#                    cipher; profile key "2."; the fixture email.
#   fixture-unkeyed  as fixture without the per-item key requirements (the D-15 fallback path).
# Roles come from structure (select.jq); names are ciphertext. The sync response is written to a
# mode-600 file in the probe state dir and deleted on exit; it never enters the repo.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}"; }

FIXTURE_EMAIL="prizm-fixture@example.com"

# Takes the sync document, --arg mode and --arg fixture_email; prints {error, rows, prefix, email, missing}.
ANALYSE_JQ="$(cat <<'JQ'
include "select";

def named($rows; $role): ($rows | map(select(.role == $role)));

# Presence-only: control and twin assigned and unkeyed.
def controls_missing($rows):
  ("control", "twin") as $role
  | named($rows; $role) as $found
  | if ($found | length) == 0 then $role
    elif $found[0].keyed then "\($role) keyed"
    else empty end;

# Exactly one cipher of the role; $check yields the names of whatever is wrong with it.
def one_of($rows; $role; $keyed; check):
  named($rows; $role) as $found
  | if ($found | length) == 0 then $role
    elif ($found | length) > 1 then "\($role) (\($found | length) found)"
    else $found[0] | (if $keyed and (.keyed | not) then "\($role) keyed" else empty end), check end;

def fixture_missing($rows; $keyed; $prefix; $email):
  controls_missing($rows),
  one_of($rows; "passkey-login"; $keyed;
    (if .fido2 >= 1 then empty else "passkey-login passkey" end),
    (if .passwordHistory >= 1 then empty else "passkey-login password history" end),
    (if .uris >= 2 then empty else "passkey-login uris" end),
    (if .uris > 0 and .uriChecksums == .uris then empty else "passkey-login uriChecksum" end),
    (if .attachments >= 1 then empty else "passkey-login attachment" end)),
  one_of($rows; "archived"; $keyed; empty),
  one_of($rows; "ssh"; $keyed;
    (if (.sshFields | length) == 3 then empty else "ssh fields (privateKey, publicKey, keyFingerprint)" end)),
  one_of($rows; "org-login"; $keyed; empty),
  (named($rows; "extra") | if length == 0 then empty else "extra ciphers (\(length))" end),
  (if $prefix == "2." then empty else "profile key prefix" end),
  (if $email == $fixture_email then empty else "email" end);

. as $doc
| (($doc.profile.key // "") | .[0:2]) as $prefix
| ($doc.profile.email // "") as $email
| (try {rows: ($doc | cipher_summary)} catch {error: .}) as $result
| if $result.error != null
  then {error: $result.error, rows: [], prefix: $prefix, email: $email, missing: null}
  else $result.rows as $rows
    | {error: null, rows: $rows, prefix: $prefix, email: $email,
       missing: (if $mode == "controls" then [controls_missing($rows)]
                 elif $mode == "fixture" then [fixture_missing($rows; true; $prefix; $email)]
                 elif $mode == "fixture-unkeyed" then [fixture_missing($rows; false; $prefix; $email)]
                 else null end)}
  end
JQ
)"

# Left-aligns tab-separated columns.
format_table() {
  awk -F '\t' '
    { for (i = 1; i <= NF; i++) { if (length($i) > w[i]) w[i] = length($i); cell[NR, i] = $i }
      if (NF > cols) cols = NF; rows = NR }
    END { for (r = 1; r <= rows; r++) {
            line = ""
            for (i = 1; i <= cols; i++) line = line sprintf("%-" w[i] "s  ", cell[r, i])
            sub(/ +$/, "", line); print line } }'
}

# sync_report <sync-file> [<mode>]: prints the summary and, with a mode, the expectation verdict.
# Returns 1 when the roles are ambiguous or the expectation fails.
sync_report() {
  local file="$1" mode="${2:-}" analysis error
  analysis="$(jq -c -L "${RIG_LIB_DIR}" --arg mode "${mode}" --arg fixture_email "${FIXTURE_EMAIL}" "${ANALYSE_JQ}" "${file}")" \
    || { echo "sync summary FAILED: the document is not a readable sync response" >&2; return 1; }

  error="$(jq -r '.error // empty' <<<"${analysis}")"
  if [[ -n "${error}" ]]; then
    if [[ -n "${mode}" ]]; then echo "expect ${mode} FAILED: ${error}"; else echo "sync summary FAILED: ${error}"; fi
    return 1
  fi

  jq -r '
    ["id", "role", "type", "keyed", "org", "archived", "fido2", "history", "uris", "checksums",
     "attachments", "ssh-fields", "revisionDate"],
    (.rows[] | [.id, .role, (.type | tostring), (if .keyed then "yes" else "no" end),
                (if .org then "yes" else "no" end), (if .archived then "yes" else "no" end),
                (.fido2 | tostring), (.passwordHistory | tostring), (.uris | tostring),
                (.uriChecksums | tostring), (.attachments | tostring),
                (if (.sshFields | length) == 0 then "-" else (.sshFields | join(",")) end),
                (.revisionDate // "-")])
    | @tsv' <<<"${analysis}" | format_table
  jq -r '"profile key prefix=\(.prefix)", "email=\(.email)",
         "ciphers total=\(.rows | length) keyed=\(.rows | map(select(.keyed)) | length)"' <<<"${analysis}"

  if [[ -n "${mode}" ]]; then
    local missing
    missing="$(jq -r '.missing | join(", ")' <<<"${analysis}")"
    if [[ -n "${missing}" ]]; then
      echo "expect ${mode} FAILED: ${missing}"
      return 1
    fi
    echo "expect ${mode} OK"
  fi
}

selftest() {
  local dir failures=0
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: the directory name is fixed
  trap "rm -rf '${dir}'" EXIT

  # A complete synthetic fixture: control, twin and the four keyed items. Values that look like
  # EncStrings are deliberate: the summary must never print them.
  jq -n '
    def c($id; $type; $date): {id: $id, type: $type, creationDate: $date, revisionDate: $date,
      organizationId: null, key: null, archivedDate: null, deletedDate: null, attachments: [],
      passwordHistory: [], login: {uris: [], fido2Credentials: []}, name: "2.ENCNAME|iv|mac"};
    def uri($n): {uri: "2.URI\($n)|iv|mac", uriChecksum: "2.SUM\($n)|iv|mac"};
    {profile: {email: "prizm-fixture@example.com", key: "2.PROFILEKEY|iv|mac"},
     ciphers: [
       (c("ctrl"; 1; "2026-10-26T10:00:00.000000Z") | .login.uris = [uri(1)]),
       (c("twin"; 1; "2026-10-26T10:01:00.000000Z") | .login.uris = [uri(2)]),
       (c("passkey"; 1; "2026-10-26T10:10:00.000000Z") | .key = "2.K|iv|mac"
         | .login.fido2Credentials = [{credentialId: "2.FIDO|iv|mac"}]
         | .passwordHistory = [{password: "2.OLD|iv|mac", lastUsedDate: "2026-10-26T10:11:00Z"}]
         | .login.uris = [uri(3), uri(4)] | .attachments = [{id: "a1", fileName: "2.FILE|iv|mac"}]),
       (c("arch"; 1; "2026-10-26T10:20:00.000000Z") | .key = "2.K|iv|mac"
         | .archivedDate = "2026-10-26T10:21:00.000000Z"),
       (c("ssh"; 5; "2026-10-26T10:30:00.000000Z") | .key = "2.K|iv|mac"
         | .sshKey = {privateKey: "2.PRIV|iv|mac", publicKey: "2.PUB|iv|mac", keyFingerprint: "2.FP|iv|mac"}),
       (c("org"; 1; "2026-10-26T10:40:00.000000Z") | .key = "2.K|iv|mac" | .organizationId = "org-1")]}
  ' > "${dir}/base.json"

  # expect_case <name> <jq filter over base.json | -> > <mode> <ok|fail> [<text the output must contain>]
  expect_case() {
    local name="$1" filter="$2" mode="$3" want="$4" text="${5:-}" out status=0
    jq "${filter}" "${dir}/base.json" > "${dir}/case.json"
    out="$(sync_report "${dir}/case.json" "${mode}" 2>&1)" || status=$?
    if [[ "${want}" == ok && "${status}" != 0 ]] || [[ "${want}" == fail && "${status}" == 0 ]]; then
      echo "selftest FAILED: ${name}: expected ${want}, exit ${status}" >&2; failures=$((failures + 1))
    elif [[ -n "${text}" && "${out}" != *"${text}"* ]]; then
      echo "selftest FAILED: ${name}: output lacks '${text}'" >&2; failures=$((failures + 1))
    fi
  }

  expect_case "valid fixture passes fixture"       '.' fixture ok "expect fixture OK"
  expect_case "valid fixture passes controls"      '.' controls ok "expect controls OK"
  expect_case "valid fixture passes fixture-unkeyed" '.' fixture-unkeyed ok
  expect_case "controls fails naming twin"         'del(.ciphers[] | select(.id == "twin"))' controls fail "twin"
  expect_case "controls fails on a keyed control"  '(.ciphers[] | select(.id == "ctrl") | .key) = "2.K|iv|mac"' controls fail "control keyed"
  expect_case "equal creationDate is ambiguous"    '(.ciphers[] | select(.id == "twin") | .creationDate) = "2026-10-26T10:00:00.000000Z"' controls fail "ambiguous"
  expect_case "missing passkey is named"           'del(.ciphers[] | select(.id == "passkey"))' fixture fail "passkey-login"
  expect_case "unkeyed items fail fixture"         '.ciphers |= map(.key = null)' fixture fail "passkey-login keyed"
  expect_case "unkeyed items pass fixture-unkeyed" '.ciphers |= map(.key = null) | .profile.key = "2.PROFILEKEY|iv|mac"' fixture-unkeyed ok
  expect_case "ssh without fingerprint is named"   '(.ciphers[] | select(.id == "ssh") | .sshKey.keyFingerprint) = null' fixture fail "ssh fields"
  expect_case "missing checksum is named"          '(.ciphers[] | select(.id == "passkey") | .login.uris[0].uriChecksum) = null' fixture fail "uriChecksum"
  expect_case "wrong email is named"               '.profile.email = "someone@example.com"' fixture fail "email"
  expect_case "extra login fails fixture"          '.ciphers += [(.ciphers[0] | .id = "more" | .creationDate = "2026-10-26T11:00:00.000000Z")]' fixture fail "extra ciphers"
  expect_case "extra login passes controls"        '.ciphers += [(.ciphers[0] | .id = "more" | .creationDate = "2026-10-26T11:00:00.000000Z")]' controls ok

  # Swapped creation order swaps control and twin.
  local roles
  roles="$(jq -c -L "${RIG_LIB_DIR}" 'include "select"; roles' "${dir}/base.json")"
  [[ "${roles}" == *'"control":"ctrl"'* && "${roles}" == *'"twin":"twin"'* ]] \
    || { echo "selftest FAILED: roles of the base fixture: ${roles}" >&2; failures=$((failures + 1)); }
  roles="$(jq -c -L "${RIG_LIB_DIR}" 'include "select";
      (.ciphers[0].creationDate) as $a | (.ciphers[1].creationDate) as $b
      | .ciphers[0].creationDate = $b | .ciphers[1].creationDate = $a | roles' "${dir}/base.json")"
  [[ "${roles}" == *'"control":"twin"'* && "${roles}" == *'"twin":"ctrl"'* ]] \
    || { echo "selftest FAILED: swapped order did not swap the roles: ${roles}" >&2; failures=$((failures + 1)); }

  # The summary never prints EncString values.
  local report
  report="$(sync_report "${dir}/base.json" fixture 2>&1)"
  if [[ "${report}" == *ENC* || "${report}" == *PROFILEKEY* || "${report}" == *"|iv|mac"* ]]; then
    echo "selftest FAILED: the summary printed an EncString value" >&2; failures=$((failures + 1))
  fi

  if (( failures > 0 )); then
    echo "sync-summary selftest FAILED: ${failures} case(s)" >&2
    return 1
  fi
  echo "sync-summary selftest OK"
}

main() {
  local version="" mode="" run_selftest=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="${2:-}"; shift 2 || die "--version needs a value" ;;
      --expect) mode="${2:-}"; shift 2 || die "--expect needs a value" ;;
      --selftest) run_selftest=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done

  if (( run_selftest )); then selftest; return; fi
  [[ -n "${version}" ]] || { usage >&2; die "--version is required"; }
  case "${mode}" in ''|controls|fixture|fixture-unkeyed) ;; *) die "unknown expectation '${mode}'." ;; esac

  rig_init "${version}"
  local out status
  out="${RIG_STATE_DIR}/sync-${RIG_VERSION}.json"
  # shellcheck disable=SC2064  # expand now: the file name is fixed
  trap "rm -f '${out}'" EXIT
  status="$(rig_api GET "/api/sync?excludeDomains=true" "${out}")" || exit 1
  [[ "${status}" == 200 ]] || die "GET /api/sync answered HTTP ${status}."
  sync_report "${out}" "${mode}"
}

main "$@"
