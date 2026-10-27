#!/usr/bin/env bash
# E-row runner for the Vaultwarden rig: the raw-API experiments of Phase 1 (D-05, D-06, D-08, D-18).
# Container only, except e6, summary and --selftest, which are offline.
#
#   scripts/rig/experiment.sh --version <1.37.3|1.37.4> roles|e1|e2|e4|e5|e7|e8|e9
#   scripts/rig/experiment.sh e6
#   scripts/rig/experiment.sh summary
#   scripts/rig/experiment.sh --selftest
#
# Rows (versions per D-08; every row except roles, e6 and summary changes server data, so plan 06
# restores snapshot fixture-v1 before each one):
#   roles  checks the fixture expectation for the D-15 outcome in provenance.md on pristine data,
#          then writes dev-vault/evidence/roles-<v>.json (role ids and profile.id); every other row
#          reads its ids from that file and never re-selects
#   e1     Prizm-shaped PUT and POST with and without encryptedFor, and with a wrong one   (both)
#   e2     what PUT without key does, and which fields a keyless PUT clears              (1.37.4)
#   e4     does PUT without archivedDate un-archive                                         (both)
#   e5     stale PUT: gap3 (full) and gap0, epoch, garbage (1.37.4 only)                    (both)
#   e6     timestamp shapes of the golden fixture, record only (offline)
#   e7     which operations bump revisionDate                                            (1.37.4)
#   e8     SSH key edit without keyFingerprint                                           (1.37.4)
#   e9     swapped uriChecksum values, stored on a clone                                 (1.37.4)
#   summary  every RESULT line of dev-vault/evidence/*.log, grouped by row and version
#
# Evidence: lines starting "RESULT <ROW> <variant> ..." in dev-vault/evidence/<row>-<version>.log
# (git-ignored): status codes, presence or absence of fields, raw revisionDate strings and server
# error messages, never an EncString, token or password.
#
# The encryptedFor rule (source review finding 4): every POST or PUT body sent to /api/ciphers or
# /api/ciphers/<id> carries encryptedFor = profile.id (bodies.jq with_uid); api() refuses to send
# one without it unless the call is one of the two E1 "without encryptedFor" variants. Requests
# without item data (/partial, /move, /collections, delete, restore, attachments, folders) carry none.
#
# Deviation from PATTERNS.md's per-row e-*.sh layout: one runner with a row argument, because every
# row shares roles-<v>.json, rig_api, the body builders and the RESULT format, and one --selftest
# can then run every row against a fake server and prove its requests offline.
# shellcheck disable=SC2016  # jq programs in single quotes use jq variables, not shell expansions
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,/^set -euo/{/^set -euo/!p}' "${BASH_SOURCE[0]}" | sed '/^# shellcheck/d'; }

GOLDEN="${PRIZM_REPO_ROOT}/Prizm/PrizmTests/Fixtures/sync-golden-1.37.4.json"
FIXTURES_DIR="${PRIZM_REPO_ROOT}/Prizm/PrizmTests/Fixtures"
PROVENANCE="${PRIZM_REPO_ROOT}/dev-vault/evidence/provenance.md"
E1A_KEYS="${PRIZM_REPO_ROOT}/dev-vault/evidence/e1a-body-keys.txt"
SLEEP_CMD="sleep"
API_IMPL=exp_api

VERSION=""
WORK_DIR=""
ROLES_FILE=""
PROFILE_ID=""
API_STATUS=""
API_OUT=""
LAST_BODY=""
CUR_LABEL=""
REQ_N=0
NO_UID_OK=0
ROW_FAILED=0
E7_LAST_OUT=""
REV=""

cleanup() { if [[ -n "${WORK_DIR}" ]]; then rm -rf "${WORK_DIR}"; fi; }

# --- transport -------------------------------------------------------------------------------

# Multipart upload of an attachment blob: field "data", filename "attachment" (Prizm's
# uploadAttachmentBitwardenHosted). rig_api only sends JSON, so this mirrors its header and token
# handling. Prints the HTTP status.
exp_upload() {
  local path="$1" out="$2" data="$3" hdr code
  rig_token_valid || rig_login
  hdr="$(mktemp "${RIG_STATE_DIR}/hdr.XXXXXX")"
  rig_headers "${hdr}"
  ( umask 077; printf 'Authorization: Bearer %s\n' "$(sed -n 2p "$(rig_token_file)")" >> "${hdr}" )
  code="$( umask 077; curl -sS --max-time 60 -o "${out}" -w '%{http_code}' -H @"${hdr}" -X POST \
      -F "data=@${data};filename=attachment;type=application/octet-stream" "${RIG_BASE}${path}")" || code="000"
  rm -f "${hdr}"
  printf '%s\n' "${code}"
}

# exp_api <METHOD|UPLOAD> <PATH> <OUT> [<BODY or DATA FILE>]
exp_api() {
  if [[ "$1" == UPLOAD ]]; then exp_upload "$2" "$3" "$4"; else rig_api "$@"; fi
}

# The encryptedFor rule, enforced where every request passes.
guard_uid() {
  local method="$1" path="$2" body="$3"
  case "${method}" in POST|PUT) ;; *) return 0 ;; esac
  [[ "${path}" =~ ^/api/ciphers(/[^/]+)?$ ]] || return 0
  [[ "${path}" != /api/ciphers/move ]] || return 0
  if [[ -z "${body}" ]] || ! jq -e 'has("encryptedFor")' "${body}" >/dev/null 2>&1; then
    (( NO_UID_OK == 1 )) || die "refusing to send ${method} ${path} without encryptedFor (every cipher body needs it on 1.37.4)."
  fi
  return 0
}

# api <METHOD|UPLOAD> <PATH> [<BODY>]: sets API_STATUS and API_OUT. Call it directly, never in $(...).
api() {
  local method="$1" path="$2" body="${3:-}"
  guard_uid "${method}" "${path}" "${body}"
  REQ_N=$((REQ_N + 1))
  API_OUT="${WORK_DIR}/resp-${REQ_N}.out"
  API_STATUS="$("${API_IMPL}" "${method}" "${path}" "${API_OUT}" ${body:+"${body}"})" \
    || die "request ${method} ${path} failed."
  [[ "${API_STATUS}" =~ ^[0-9]{3}$ ]] || die "request ${method} ${path} gave no HTTP status."
}

rig_sleep() { "${SLEEP_CMD}" "$1"; }

# --- evidence and small helpers ---------------------------------------------------------------

# result <ROW> <variant> <text...>: prints the line and appends it to dev-vault/evidence/<row>-<version>.log.
result() {
  local row="$1" variant="$2"
  shift 2
  local line="RESULT ${row} ${variant} $*"
  printf '%s\n' "${line}"
  rig_evidence "$(tr '[:upper:]' '[:lower:]' <<<"${row}")" "${line}"
}

# One line, at most 200 characters, of the server's error message in API_OUT.
api_message() {
  local text
  text="$(jq -r '([.message?, .errorModel.message?, .error_description?,
        (.error? | if type == "object" then ((.reason // "") + " " + (.description // ""))
                   elif type == "string" then . else null end)]
        | map(select(. != null and . != "" and . != " ")) | .[0] // "") | tostring' "${API_OUT}" 2>/dev/null \
      || head -c 120 "${API_OUT}")"
  printf '%s' "${text}" | tr '\n"' "  " | cut -c1-200
}

# Raw revisionDate of a cipher into REV (a string, never reformatted).
fetch_revision() {
  fetch_cipher "$1" "${WORK_DIR}/rev.json"
  REV="$(jq -r '.revisionDate' "${WORK_DIR}/rev.json")"
}

# fetch_cipher <id> <file>: GET /api/ciphers/<id> into <file>.
fetch_cipher() {
  api GET "/api/ciphers/$1"
  [[ "${API_STATUS}" == 200 ]] || die "GET /api/ciphers/$1 answered HTTP ${API_STATUS}."
  cp "${API_OUT}" "$2"
}

# build_body <variant> <source.json> <donor.json> <uid> <lkrd>: the body on stdout (bodies.jq).
build_body() {
  jq -L "${RIG_LIB_DIR}" --arg name "$1" --arg uid "$4" --arg lkrd "$5" --slurpfile donor "$3" \
    'include "bodies"; variant($name; $uid; $donor[0]; $lkrd)' "$2"
}

# send_variant <row> <label> <METHOD> <PATH> <variant> <source.json> [--no-uid] [--uid <v>]
#              [--donor <f>] [--lkrd <s>] [--expect <status>]
# Builds the body, sends it and records "RESULT <row> <label> status=..."; leaves API_STATUS,
# API_OUT and LAST_BODY for the caller.
send_variant() {
  local row="$1" label="$2" method="$3" path="$4" variant="$5" src="$6"
  shift 6
  local uid="${PROFILE_ID}" donor="${src}" lkrd="" expect="" no_uid=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-uid) no_uid=1; shift ;;
      --uid) uid="$2"; shift 2 ;;
      --donor) donor="$2"; shift 2 ;;
      --lkrd) lkrd="$2"; shift 2 ;;
      --expect) expect="$2"; shift 2 ;;
      *) die "send_variant: unknown option $1" ;;
    esac
  done
  LAST_BODY="${WORK_DIR}/body-${row}-${label}.json"
  build_body "${variant}" "${src}" "${donor}" "${uid}" "${lkrd}" > "${LAST_BODY}" \
    || die "could not build the ${variant} body for ${label}."
  CUR_LABEL="${label}"
  NO_UID_OK="${no_uid}"
  api "${method}" "${path}" "${LAST_BODY}"
  NO_UID_OK=0
  CUR_LABEL=""
  record_status "${row}" "${label}" "${method}" "${expect}"
}

# record_status <row> <label> <method> [<expected status>]: the RESULT line for the last request.
record_status() {
  local row="$1" label="$2" method="$3" expect="${4:-}" line created
  line="status=${API_STATUS}"
  if [[ -n "${expect}" ]]; then
    line+=" expected=${expect} match=$([[ "${API_STATUS}" == "${expect}" ]] && echo yes || echo no)"
  fi
  if [[ "${method}" == POST && "${API_STATUS}" == 200 ]]; then
    created="$(jq -r '.id // empty' "${API_OUT}" 2>/dev/null || true)"
    [[ -z "${created}" ]] || line+=" created=${created}"
  fi
  if (( 10#${API_STATUS} >= 400 )); then line+=" message=\"$(api_message)\""; fi
  result "${row}" "${label}" "${line}"
}

provenance_value() { sed -n "s/^$1:[[:space:]]*//p" "${PROVENANCE}" 2>/dev/null | head -n 1; }

d15_outcome() {
  local outcome
  outcome="$(provenance_value d15-outcome)"
  case "${outcome}" in
    authored|fallback) printf '%s' "${outcome}" ;;
    *) die "dev-vault/evidence/provenance.md has no usable d15-outcome ('${outcome}')." ;;
  esac
}

d15_phrase() {
  local digest
  digest="$(sed -n 's/^authoring-digest:[[:space:]]*sha256:\(.\{8\}\).*/\1/p' "${PROVENANCE}" | head -n 1)"
  printf 'keyed fixture not reproducible with extension 2026.10.0 and the injected flag on 1.37.3 sha256:%s' "${digest}"
}

only_1374() { [[ "${VERSION}" == 1.37.4 ]] || die "row $1 runs on 1.37.4 only (D-08)."; }

load_roles() {
  ROLES_FILE="${RIG_EVIDENCE_DIR}/roles-${VERSION}.json"
  [[ -f "${ROLES_FILE}" ]] || die "run 'scripts/rig/experiment.sh --version ${VERSION} roles' first (no ${ROLES_FILE})."
  PROFILE_ID="$(jq -r '.profileId // empty' "${ROLES_FILE}")"
  [[ -n "${PROFILE_ID}" ]] || die "${ROLES_FILE} has no profileId."
}

role_id() {
  local id
  id="$(jq -r --arg r "$1" '.roles[$r] // empty' "${ROLES_FILE}")"
  [[ -n "${id}" ]] || die "${ROLES_FILE} has no role '$1'."
  printf '%s' "${id}"
}

# Pristine-data signal: the control's revisionDate against provenance.md (plan 06 restores
# fixture-v1 before each row; a mismatch means the row started on modified data).
record_baseline() {
  local expect actual pristine
  expect="$(provenance_value control-revision-date)"
  fetch_revision "$(role_id control)"
  actual="${REV}"
  if [[ -z "${expect}" ]]; then pristine=unknown
  elif [[ "${actual}" == "${expect}" ]]; then pristine=yes
  else pristine=no; fi
  result "$1" baseline "control-revision=${actual} pristine=${pristine}"
}

epoch_ns() { date -u -d "$1" +%s%N; }

# --- rows --------------------------------------------------------------------------------------

# role -> id, profile id and raw revisionDates from a sync document, on stdout.
build_roles_json() {
  jq -L "${RIG_LIB_DIR}" --arg version "${VERSION}" 'include "select";
    . as $doc
    | {version: $version, profileId: .profile.id, roles: roles,
       revisionDates: (roles | with_entries(.value as $id | .value = ($doc.ciphers[] | select(.id == $id) | .revisionDate)))}' "$1"
}

row_roles() {
  local mode out sync
  case "$(d15_outcome)" in authored) mode=fixture ;; fallback) mode=fixture-unkeyed ;; esac
  out="$("${RIG_LIB_DIR}/sync-summary.sh" --version "${VERSION}" --expect "${mode}" 2>&1)" \
    || { printf '%s\n' "${out}" | tail -n 3 >&2; die "the rig does not hold pristine fixture data (expect ${mode} failed)."; }
  printf '%s\n' "${out}" | tail -n 1
  sync="${WORK_DIR}/sync.json"
  api GET "/api/sync?excludeDomains=true"
  [[ "${API_STATUS}" == 200 ]] || die "GET /api/sync answered HTTP ${API_STATUS}."
  cp "${API_OUT}" "${sync}"
  mkdir -p "${RIG_EVIDENCE_DIR}"
  ( umask 077; build_roles_json "${sync}" > "${RIG_EVIDENCE_DIR}/roles-${VERSION}.json" ) \
    || die "could not derive the roles."
  ROLES_FILE="${RIG_EVIDENCE_DIR}/roles-${VERSION}.json"
  jq -e '.roles | has("control") and has("twin") and has("passkey-login") and has("archived") and has("ssh") and has("org-login")' \
    "${ROLES_FILE}" >/dev/null || die "the fixture lacks a role (see ${ROLES_FILE})."
  result ROLES "${VERSION}" "written roles=$(jq -r '.roles | keys | join(",")' "${ROLES_FILE}") expect-mode=${mode}"
}

row_e1() {
  record_baseline E1
  local control twin
  control="$(role_id control)"
  twin="$(role_id twin)"
  fetch_cipher "${control}" "${WORK_DIR}/control.json"
  fetch_cipher "${twin}" "${WORK_DIR}/twin.json"
  # 1.37.4 requires encryptedFor (missing: 422 with Rocket's generic body; wrong value on create:
  # 422 "Invalid user cipher"); 1.37.3 has no such field and should accept everything.
  local e_without=200 e_wrong=200
  if [[ "${VERSION}" == 1.37.4 ]]; then e_without=422 e_wrong=422; fi
  send_variant E1 put-prizm-without-encryptedFor PUT "/api/ciphers/${control}" prizm "${WORK_DIR}/control.json" --no-uid --expect "${e_without}"
  send_variant E1 put-prizm-with-encryptedFor PUT "/api/ciphers/${control}" prizm-uid "${WORK_DIR}/control.json" --expect 200
  send_variant E1 post-prizm-without-encryptedFor POST /api/ciphers create-prizm "${WORK_DIR}/twin.json" --no-uid --expect "${e_without}"
  send_variant E1 post-prizm-with-encryptedFor POST /api/ciphers create-prizm-uid "${WORK_DIR}/twin.json" --expect 200
  send_variant E1 post-prizm-wrong-encryptedFor POST /api/ciphers create-prizm-uid "${WORK_DIR}/twin.json" \
    --uid "$(cat /proc/sys/kernel/random/uuid)" --expect "${e_wrong}"
}

# State of one field after a PUT: present, empty ([]), or null (null or absent).
FIELD_STATES='def st: if . == null then "null" elif (type == "array" and length == 0) then "empty" else "present" end;
  "key=\(.key | st) fido2=\(.login.fido2Credentials | st) history=\(.passwordHistory | st)
   passwordRevisionDate=\(.login.passwordRevisionDate | st) autofillOnPageLoad=\(.login.autofillOnPageLoad | st)
   uriChecksums=\(if ([.login.uris[]?.uriChecksum | select(. != null)] | length) > 0 then "present" else "null" end)"
  | gsub("\n +"; " ")'

row_e2() {
  if [[ "$(d15_outcome)" == fallback ]]; then
    result E2 skipped "$(d15_phrase)"
    return 0
  fi
  only_1374 e2
  record_baseline E2
  local passkey twin clone before_att after_att same
  passkey="$(role_id passkey-login)"
  twin="$(role_id twin)"
  fetch_cipher "${passkey}" "${WORK_DIR}/passkey.json"
  fetch_cipher "${twin}" "${WORK_DIR}/twin.json"

  # The clone must come from the pristine keyed item, so it is created before (i) touches it.
  send_variant E2 clone-create POST /api/ciphers clone-echo-uid "${WORK_DIR}/passkey.json" --expect 200
  clone="$(jq -r '.id // empty' "${API_OUT}" 2>/dev/null || true)"

  # (i) PUT the echo body without key on the keyed item.
  before_att="$(jq '.attachments | length' "${WORK_DIR}/passkey.json")"
  send_variant E2 i-echo-without-key PUT "/api/ciphers/${passkey}" echo-nokey-uid "${WORK_DIR}/passkey.json" --expect 200
  fetch_cipher "${passkey}" "${WORK_DIR}/passkey-after.json"
  after_att="$(jq '.attachments | length' "${WORK_DIR}/passkey-after.json")"
  same="$(jq -n --slurpfile a "${WORK_DIR}/passkey.json" --slurpfile b "${WORK_DIR}/passkey-after.json" \
    'if ($a[0].name == $b[0].name and $a[0].login.username == $b[0].login.username
         and $a[0].login.password == $b[0].login.password) then "yes" else "no" end' -r)"
  result E2 i-after "key-before=$(jq -r 'if .key != null then "present" else "null" end' "${WORK_DIR}/passkey.json")" \
    "key-after=$(jq -r 'if .key != null then "present" else "null" end' "${WORK_DIR}/passkey-after.json")" \
    "attachments-before=${before_att} attachments-after=${after_att} field-ciphertexts-unchanged=${same} expected=key-cleared"

  # (ii) PUT a Prizm-shaped body that borrows the twin's ciphertext onto the keyed clone.
  if [[ -z "${clone}" ]]; then
    result E2 ii-skipped "clone was not created (status ${API_STATUS})"
    return 0
  fi
  fetch_cipher "${clone}" "${WORK_DIR}/clone.json"
  result E2 ii-clone-baseline "$(jq -r "${FIELD_STATES}" "${WORK_DIR}/clone.json")"
  send_variant E2 ii-borrow-put PUT "/api/ciphers/${clone}" borrow-uid "${WORK_DIR}/clone.json" --donor "${WORK_DIR}/twin.json" --expect 200
  fetch_cipher "${clone}" "${WORK_DIR}/clone-after.json"
  result E2 ii-after "$(jq -r "${FIELD_STATES}" "${WORK_DIR}/clone-after.json")"
}

row_e4() {
  record_baseline E4
  local archived
  archived="$(role_id archived)"
  fetch_cipher "${archived}" "${WORK_DIR}/archived.json"
  send_variant E4 put-echo-without-archivedDate PUT "/api/ciphers/${archived}" echo-noarchived-uid "${WORK_DIR}/archived.json" --expect 200
  fetch_cipher "${archived}" "${WORK_DIR}/archived-after.json"
  result E4 after "archived-before=$(jq -r 'if .archivedDate != null then "yes" else "no" end' "${WORK_DIR}/archived.json")" \
    "archived-after=$(jq -r 'if .archivedDate != null then "yes" else "no" end' "${WORK_DIR}/archived-after.json") expected=un-archived"
}

# publish_stale_body <response file>: moves the stale-PUT 400 body to the fixtures directory, after
# capture-sync.sh --verify passed. Plan 06's live gap3 run on 1.37.4 is the only step that creates
# this file.
publish_stale_body() {
  local tmp="${WORK_DIR}/stale-put-400.json" dest partial
  cp "$1" "${tmp}"   # byte for byte
  if [[ "${VERSION}" == 1.37.4 ]]; then
    if "${RIG_LIB_DIR}/capture-sync.sh" --verify "${tmp}" >/dev/null 2>&1; then
      mkdir -p "${FIXTURES_DIR}"
      dest="${FIXTURES_DIR}/stale-put-400-1.37.4.json"
      partial="$(mktemp "${FIXTURES_DIR}/.stale-put-400.XXXXXX")"
      cp "${tmp}" "${partial}"
      chmod 644 "${partial}"
      mv -f "${partial}" "${dest}"
      result E5 gap3 "stale-fixture=written file=stale-put-400-1.37.4.json"
    else
      result E5 gap3 "stale-fixture=rejected-by-verify (not written)"
      ROW_FAILED=1
    fi
  else
    mkdir -p "${RIG_EVIDENCE_DIR}"
    cp "${tmp}" "${RIG_EVIDENCE_DIR}/stale-put-400-${VERSION}.json"
    result E5 gap3 "stale-body=evidence/stale-put-400-${VERSION}.json (1.37.3 body stays out of the fixtures)"
  fi
}

# e5_variant <name> <wait seconds> <r0|epoch|garbage> <expected stale status>
# Order matters (D-18 as corrected 2026-10-26): fresh base write, reference GET (R0), wait,
# competing write by "the other device", then the stale PUT carrying lastKnownRevisionDate.
# Vaultwarden rejects only when the competing write is at least 2 s after R0.
e5_variant() {
  local name="$1" wait_s="$2" mode="$3" expect="$4" twin r0 r1 gap lk after stale_out stale_status
  twin="$(role_id twin)"
  fetch_cipher "${twin}" "${WORK_DIR}/e5-${name}-pre.json"
  send_variant E5 "${name}-base-write" PUT "/api/ciphers/${twin}" echo-uid "${WORK_DIR}/e5-${name}-pre.json" --expect 200
  fetch_cipher "${twin}" "${WORK_DIR}/e5-${name}-r0.json"
  r0="$(jq -r '.revisionDate' "${WORK_DIR}/e5-${name}-r0.json")"
  if (( wait_s > 0 )); then rig_sleep "${wait_s}"; fi
  send_variant E5 "${name}-competing-write" PUT "/api/ciphers/${twin}" echo-uid "${WORK_DIR}/e5-${name}-r0.json" --expect 200
  fetch_cipher "${twin}" "${WORK_DIR}/e5-${name}-r1.json"
  r1="$(jq -r '.revisionDate' "${WORK_DIR}/e5-${name}-r1.json")"
  gap=$(( ($(epoch_ns "${r1}") - $(epoch_ns "${r0}")) / 1000000 ))
  case "${mode}" in
    r0) lk="${r0}" ;;
    epoch) lk="1970-01-01T00:00:00.000Z" ;;
    garbage) lk="not-a-date" ;;
    *) die "unknown e5 mode ${mode}" ;;
  esac
  result E5 "${name}" "timing wait=${wait_s}s gap-ms=${gap} R0=${r0} R1=${r1} lastKnownRevisionDate=${lk}"
  send_variant E5 "${name}-stale-put" PUT "/api/ciphers/${twin}" stale-uid "${WORK_DIR}/e5-${name}-r1.json" --lkrd "${lk}" --expect "${expect}"
  stale_out="${API_OUT}"
  stale_status="${API_STATUS}"
  fetch_cipher "${twin}" "${WORK_DIR}/e5-${name}-after.json"
  after="$(jq -r '.revisionDate' "${WORK_DIR}/e5-${name}-after.json")"
  result E5 "${name}" "revision-after-stale=${after} unchanged-since-competing-write=$([[ "${after}" == "${r1}" ]] && echo yes || echo no)"
  if [[ "${name}" == gap3 && "${stale_status}" == 400 ]]; then
    publish_stale_body "${stale_out}"
  fi
}

row_e5() {
  record_baseline E5
  e5_variant gap3 3 r0 400
  if [[ "${VERSION}" == 1.37.4 ]]; then
    e5_variant gap0 0 r0 200
    e5_variant epoch 0 epoch 400
    e5_variant garbage 0 garbage 200
  fi
}

row_e6() {
  [[ -f "${GOLDEN}" ]] || die "the golden fixture ${GOLDEN} does not exist (plan 05 Task 1)."
  local line
  while IFS= read -r line; do
    result E6 "${line%%$'\t'*}" "${line#*$'\t'}"
  done < <(jq -r '
    def micros: "9999-99-99T99:99:99.999999Z";
    [{field: "revisionDate", client: false, values: ([.ciphers[]?.revisionDate] + [.folders[]?.revisionDate])},
     {field: "creationDate", client: false, values: [.ciphers[]?.creationDate]},
     {field: "deletedDate", client: false, values: [.ciphers[]?.deletedDate]},
     {field: "archivedDate", client: false, values: [.ciphers[]?.archivedDate]},
     {field: "login.passwordRevisionDate", client: false, values: [.ciphers[]? | .login? | select(. != null) | .passwordRevisionDate]},
     {field: "passwordHistory[].lastUsedDate", client: false, values: [.ciphers[]? | .passwordHistory[]? | .lastUsedDate]},
     {field: "login.fido2Credentials[].creationDate", client: true, values: [.ciphers[]? | .login? | select(. != null) | .fido2Credentials[]? | .creationDate]}]
    | .[] | . as $f
    | ($f.values | map(select(. != null))) as $v
    | (($f.values | length) - ($v | length)) as $nulls
    | if ($v | length) == 0
      then "\($f.field)\tvalues=0 nulls=\($nulls) expected=n/a"
      else ($v | map(gsub("[0-9]"; "9")) | group_by(.) | .[]
            | "\($f.field)\tshape=\(.[0]) count=\(length) nulls=\($nulls) expected=\(if $f.client then "client-format-kept" else "micros-Z" end)"
              + (if $f.client then "" else " match=\(if .[0] == micros then "yes" else "no" end)" end))
      end' "${GOLDEN}")
}

# revision_of-style op for E7: <label> <expect-bump yes|no> <cipher id whose revisionDate is watched> <METHOD> <PATH> [<body>]
e7_op() {
  local label="$1" expect="$2" id="$3" method="$4" path="$5" body="${6:-}" before after bumped
  fetch_revision "${id}"
  before="${REV}"
  CUR_LABEL="${label}"
  api "${method}" "${path}" ${body:+"${body}"}
  CUR_LABEL=""
  # The watched revisionDate is fetched with another request, which replaces API_OUT; callers
  # that need the operation's own answer read E7_LAST_OUT.
  E7_LAST_OUT="${API_OUT}"
  local op_status="${API_STATUS}"
  fetch_revision "${id}"
  after="${REV}"
  bumped=no
  [[ "${before}" == "${after}" ]] || bumped=yes
  result E7 "${label}" "status=${op_status} before=${before} after=${after} bumped=${bumped} expected-bump=${expect} match=$([[ "${bumped}" == "${expect}" ]] && echo yes || echo no)"
  if (( 10#${op_status} >= 400 )); then
    API_OUT="${E7_LAST_OUT}"
    result E7 "${label}" "message=\"$(api_message)\""
  fi
}

row_e7() {
  only_1374 e7
  record_baseline E7
  local twin passkey org d folder att
  twin="$(role_id twin)"
  passkey="$(role_id passkey-login)"
  org="$(role_id org-login)"
  fetch_cipher "${twin}" "${WORK_DIR}/twin.json"
  fetch_cipher "${passkey}" "${WORK_DIR}/passkey.json"
  fetch_cipher "${org}" "${WORK_DIR}/org.json"

  # The disposable cipher: a clone of the unkeyed twin, so the fixture items stay untouched.
  send_variant E7 disposable-create POST /api/ciphers clone-echo-uid "${WORK_DIR}/twin.json" --expect 200
  d="$(jq -r '.id // empty' "${API_OUT}" 2>/dev/null || true)"
  [[ -n "${d}" ]] || die "E7 could not create the disposable cipher (HTTP ${API_STATUS})."
  fetch_cipher "${d}" "${WORK_DIR}/e7-d.json"

  build_body echo-uid "${WORK_DIR}/e7-d.json" "${WORK_DIR}/e7-d.json" "${PROFILE_ID}" "" > "${WORK_DIR}/e7-echo.json"
  e7_op echo-put-control yes "${d}" PUT "/api/ciphers/${d}" "${WORK_DIR}/e7-echo.json"

  jq -n '{favorite: true, folderId: null}' > "${WORK_DIR}/e7-fav.json"
  e7_op partial-favorite no "${d}" PUT "/api/ciphers/${d}/partial" "${WORK_DIR}/e7-fav.json"

  jq -n --slurpfile t "${WORK_DIR}/twin.json" '{name: $t[0].name}' > "${WORK_DIR}/e7-folder.json"
  CUR_LABEL="folder-create"
  api POST /api/folders "${WORK_DIR}/e7-folder.json"
  CUR_LABEL=""
  record_status E7 folder-create POST ""
  folder="$(jq -r '.id // empty' "${API_OUT}" 2>/dev/null || true)"
  if [[ -n "${folder}" ]]; then
    jq -n --arg id "${d}" --arg folder "${folder}" '{ids: [$id], folderId: $folder}' > "${WORK_DIR}/e7-move.json"
    e7_op move-to-folder no "${d}" PUT /api/ciphers/move "${WORK_DIR}/e7-move.json"
    jq -n --arg folder "${folder}" '{favorite: true, folderId: $folder}' > "${WORK_DIR}/e7-partial-folder.json"
    e7_op partial-folder no "${d}" PUT "/api/ciphers/${d}/partial" "${WORK_DIR}/e7-partial-folder.json"
  else
    result E7 move-skipped "folder was not created (status ${API_STATUS})"
  fi

  e7_op archive no "${d}" PUT "/api/ciphers/${d}/archive"
  e7_op unarchive no "${d}" PUT "/api/ciphers/${d}/unarchive"

  # Attachment create, upload and delete with EncStrings borrowed from the fixture's own attachment.
  jq -n --slurpfile p "${WORK_DIR}/passkey.json" \
    '{key: $p[0].attachments[0].key, fileName: $p[0].attachments[0].fileName, fileSize: 8}' > "${WORK_DIR}/e7-att.json"
  e7_op attachment-create no "${d}" POST "/api/ciphers/${d}/attachment/v2" "${WORK_DIR}/e7-att.json"
  att="$(jq -r '.attachmentId // empty' "${E7_LAST_OUT}" 2>/dev/null || true)"
  if [[ -n "${att}" ]]; then
    printf 'prizm-ok' > "${WORK_DIR}/e7-blob.bin"
    e7_op attachment-upload no "${d}" UPLOAD "/api/ciphers/${d}/attachment/${att}" "${WORK_DIR}/e7-blob.bin"
    e7_op attachment-delete no "${d}" DELETE "/api/ciphers/${d}/attachment/${att}"
  else
    result E7 attachment-skipped "no attachmentId in the create answer (status ${API_STATUS})"
  fi

  e7_op delete yes "${d}" PUT "/api/ciphers/${d}/delete"
  e7_op restore yes "${d}" PUT "/api/ciphers/${d}/restore"

  # The org item's collection update, with its current memberships: no change of data.
  jq '{collectionIds: (.collectionIds // [])}' "${WORK_DIR}/org.json" > "${WORK_DIR}/e7-coll.json"
  e7_op collections-org-login no "${org}" PUT "/api/ciphers/${org}/collections" "${WORK_DIR}/e7-coll.json"
  local has_rev
  has_rev="$(jq -r 'if (.revisionDate? // null) != null then "yes" else "no" end' "${E7_LAST_OUT}" 2>/dev/null || true)"
  result E7 collections-org-login "response-has-revisionDate=${has_rev:-no}"
}

row_e8() {
  only_1374 e8
  record_baseline E8
  local ssh
  ssh="$(role_id ssh)"
  fetch_cipher "${ssh}" "${WORK_DIR}/ssh.json"
  local present='[(.sshKey // {}) | to_entries[] | select(.value != null and .value != "") | .key] | sort | join(",")'
  result E8 before "sshKey-fields=$(jq -r "${present}" "${WORK_DIR}/ssh.json")"
  send_variant E8 prizm-put PUT "/api/ciphers/${ssh}" prizm-uid "${WORK_DIR}/ssh.json" --expect 200
  fetch_cipher "${ssh}" "${WORK_DIR}/ssh-after.json"
  result E8 after "sshKey=$(jq -r 'if .sshKey == null then "null" else "present" end' "${WORK_DIR}/ssh-after.json")" \
    "sshKey-fields=$(jq -r "${present}" "${WORK_DIR}/ssh-after.json") keyFingerprint=$(jq -r 'if (.sshKey.keyFingerprint // null) != null then "present" else "absent" end' "${WORK_DIR}/ssh-after.json") expected=sshKey-null"
}

row_e9() {
  if [[ "$(d15_outcome)" == fallback ]]; then
    result E9 skipped "$(d15_phrase)"
    return 0
  fi
  only_1374 e9
  record_baseline E9
  local passkey clone
  passkey="$(role_id passkey-login)"
  fetch_cipher "${passkey}" "${WORK_DIR}/passkey.json"
  send_variant E9 clone-create POST /api/ciphers clone-echo-uid "${WORK_DIR}/passkey.json" --expect 200
  clone="$(jq -r '.id // empty' "${API_OUT}" 2>/dev/null || true)"
  [[ -n "${clone}" ]] || die "E9 could not create the clone (HTTP ${API_STATUS})."
  fetch_cipher "${clone}" "${WORK_DIR}/clone.json"
  send_variant E9 swap-put PUT "/api/ciphers/${clone}" swap-uid "${WORK_DIR}/clone.json" --expect 200
  fetch_cipher "${clone}" "${WORK_DIR}/clone-after.json"
  result E9 after "swapped-values-stored=$(jq -n --slurpfile a "${WORK_DIR}/clone.json" --slurpfile b "${WORK_DIR}/clone-after.json" -r \
    'if ($a[0].login.uris[0].uriChecksum == $b[0].login.uris[1].uriChecksum
         and $a[0].login.uris[1].uriChecksum == $b[0].login.uris[0].uriChecksum
         and $a[0].login.uris[0].uriChecksum != $a[0].login.uris[1].uriChecksum) then "yes" else "no" end')" "clone=${clone} client-check=plan-06"
}

row_summary() {
  local dir="${PRIZM_REPO_ROOT}/dev-vault/evidence" file name row version
  shopt -s nullglob
  for file in "${dir}"/*.log; do
    name="$(basename "${file}" .log)"
    row="${name%-*}"
    version="${name##*-}"
    if grep -q 'RESULT' "${file}"; then
      printf '## %s %s\n' "${row}" "${version}"
      grep 'RESULT' "${file}"
    fi
  done
  shopt -u nullglob
}

# --- selftest: every body builder and every row, offline ---------------------------------------

FAKE_DIR=""

fake_now() { date -u -d "+$(cat "${FAKE_DIR}/offset") seconds" +%Y-%m-%dT%H:%M:%S.%6NZ; }
fake_sleep() { echo "SLEEP $1" >> "${FAKE_DIR}/reqlog"; echo $(( $(cat "${FAKE_DIR}/offset") + $1 )) > "${FAKE_DIR}/offset"; }

# fake_api: a small stand-in for Vaultwarden, enough for the rows to run to the end and for
# --selftest to inspect every request. Version-sensitive on encryptedFor like the real servers.
fake_api() {
  local method="$1" path="$2" out="$3" body="${4:-}" status=200 id uid_flag=na keys="-" now b n lk cur_ns lk_ns
  if [[ "${method}" == UPLOAD ]]; then
    keys="data"
  elif [[ -n "${body}" ]]; then
    keys="$(jq -r 'keys | join(",")' "${body}")"
    if jq -e 'has("encryptedFor")' "${body}" >/dev/null; then uid_flag=yes; else uid_flag=no; fi
  fi
  printf '%s %s uid=%s body=%s label=%s\n' "${method}" "${path}" "${uid_flag}" "${keys}" "${CUR_LABEL:--}" >> "${FAKE_DIR}/reqlog"
  : > "${out}"
  now="$(fake_now)"
  case "${method} ${path}" in
    "GET /api/ciphers/"*)
      id="${path#/api/ciphers/}"
      if [[ -f "${FAKE_DIR}/store/${id}.json" ]]; then cp "${FAKE_DIR}/store/${id}.json" "${out}"
      else status=404; echo '{"message":"Cipher doesn'"'"'t exist"}' > "${out}"; fi ;;
    "PUT /api/ciphers/move") ;;
    "PUT /api/ciphers/"*/partial)
      id="${path#/api/ciphers/}"; id="${id%/partial}"
      jq --slurpfile b "${body}" '.favorite = $b[0].favorite | .folderId = $b[0].folderId' "${FAKE_DIR}/store/${id}.json" > "${out}"
      cp "${out}" "${FAKE_DIR}/store/${id}.json" ;;
    "PUT /api/ciphers/"*/collections) ;;
    "PUT /api/ciphers/"*/archive|"PUT /api/ciphers/"*/unarchive) ;;
    "PUT /api/ciphers/"*/delete|"PUT /api/ciphers/"*/restore)
      id="${path#/api/ciphers/}"; id="${id%/*}"
      jq --arg now "${now}" '.revisionDate = $now' "${FAKE_DIR}/store/${id}.json" > "${FAKE_DIR}/tmp.json"
      mv "${FAKE_DIR}/tmp.json" "${FAKE_DIR}/store/${id}.json" ;;
    "PUT /api/ciphers/"*)
      id="${path#/api/ciphers/}"
      if [[ "${RIG_VERSION}" == 1.37.4 && "${uid_flag}" != yes ]]; then
        status=422; echo '{"error":{"code":422,"reason":"Unprocessable Entity","description":"The request was well-formed but was unable to be followed due to semantic errors."}}' > "${out}"
      else
        lk="$(jq -r '.lastKnownRevisionDate // empty' "${body}")"
        cur_ns="$(epoch_ns "$(jq -r '.revisionDate' "${FAKE_DIR}/store/${id}.json")")"
        if [[ -n "${lk}" ]] && lk_ns="$(epoch_ns "${lk}" 2>/dev/null)" && (( (cur_ns - lk_ns) / 1000000000 > 1 )); then
          status=400
          echo '{"message":"The client copy of this cipher is out of date. Resync the client and try again.","object":"error"}' > "${out}"
        else
          jq --slurpfile b "${body}" --arg now "${now}" \
            '. * $b[0] | .revisionDate = $now | .key = ($b[0].key // null) | .archivedDate = ($b[0].archivedDate // null)
             | .passwordHistory = ($b[0].passwordHistory // []) | del(.encryptedFor, .lastKnownRevisionDate)' \
            "${FAKE_DIR}/store/${id}.json" > "${out}"
          cp "${out}" "${FAKE_DIR}/store/${id}.json"
        fi
      fi ;;
    "POST /api/ciphers")
      if [[ "${RIG_VERSION}" == 1.37.4 && "${uid_flag}" != yes ]]; then
        status=422; echo '{"error":{"code":422,"reason":"Unprocessable Entity","description":"The request was well-formed but was unable to be followed due to semantic errors."}}' > "${out}"
      elif [[ "${RIG_VERSION}" == 1.37.4 && "$(jq -r '.encryptedFor' "${body}")" != "${PROFILE_ID}" ]]; then
        status=422; echo '{"message":"Invalid user cipher","object":"error"}' > "${out}"
      else
        n=$(( $(cat "${FAKE_DIR}/clone-n") + 1 )); echo "${n}" > "${FAKE_DIR}/clone-n"
        id="00000000-0000-4000-8000-ffff$(printf '%08d' "${n}")"
        jq --arg id "${id}" --arg now "${now}" '. + {id: $id, revisionDate: $now, object: "cipherDetails", attachments: [], passwordHistory: (.passwordHistory // [])} | del(.encryptedFor)' "${body}" > "${out}"
        cp "${out}" "${FAKE_DIR}/store/${id}.json"
      fi ;;
    "POST /api/folders") echo '{"id":"00000000-0000-4000-8000-f00000000001","object":"folder"}' > "${out}" ;;
    "POST /api/ciphers/"*/attachment/v2) echo '{"attachmentId":"a0000000000000000099","fileUploadType":1,"object":"attachment-fileUpload"}' > "${out}" ;;
    "UPLOAD /api/ciphers/"*/attachment/*) ;;
    "DELETE /api/ciphers/"*/attachment/*) ;;
    *) status=404; echo '{"message":"no route"}' > "${out}" ;;
  esac
  b="${status}"
  printf '%s\n' "${b}"
}

selftest() {
  local dir failures=0 name
  [[ -f "${GOLDEN}" ]] || die "selftest needs the golden fixture ${GOLDEN} (plan 05 Task 1)."
  [[ -f "${E1A_KEYS}" ]] || die "selftest needs ${E1A_KEYS} (plan 04) to compare with real Prizm's body."
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: the directory name is fixed
  trap "rm -rf '${dir}'" EXIT
  fail() { echo "selftest FAILED: $1" >&2; failures=$((failures + 1)); }

  # --- part 1: body key sets, from the golden fixture ---
  local roles_json="${dir}/roles.json" pre="00000000-0000-4000-8000-"
  VERSION=1.37.4
  RIG_VERSION=1.37.4
  build_roles_json "${GOLDEN}" > "${roles_json}" || { echo "selftest FAILED: roles from the golden fixture" >&2; return 1; }
  local uid role id
  uid="$(jq -r .profileId "${roles_json}")"
  for role in control twin passkey-login archived ssh org-login; do
    id="$(jq -r --arg r "${role}" '.roles[$r]' "${roles_json}")"
    [[ "${id}" == "${pre}"* ]] || fail "role ${role} missing from the golden fixture"
    jq --arg id "${id}" '.ciphers[] | select(.id == $id)' "${GOLDEN}" > "${dir}/c-${role}.json"
  done
  # A source that also carries the keys the builders must never copy.
  jq '.data = "{}" | .partialData = "{}" | .login.uri = "2.legacy" | .viewPassword = true' "${dir}/c-passkey-login.json" > "${dir}/c-dirty.json"

  local forbidden_prizm='key passwordHistory archivedDate fido2Credentials uriChecksum keyFingerprint data partialData lastKnownRevisionDate revisionDate creationDate deletedDate attachments object edit permissions viewPassword organizationUseTotp'
  local forbidden_echo='object edit permissions attachments revisionDate creationDate deletedDate data partialData viewPassword organizationUseTotp'
  has_none() {  # <file> <space separated keys>: no object anywhere has any of these keys
    jq -e --arg ks "$2" '($ks | split(" ")) as $k | [.. | objects | keys[]] | any(. as $x | $k | index($x)) | not' "$1" >/dev/null
  }
  has_none_top() {  # same, top level only (fido2 credentials legitimately carry a creationDate)
    jq -e --arg ks "$2" '($ks | split(" ")) as $k | [keys[]] | any(. as $x | $k | index($x)) | not' "$1" >/dev/null
  }
  local v src body
  for v in $(jq -L "${RIG_LIB_DIR}" -n -r 'include "bodies"; all_variants[]'); do
    for role in control twin passkey-login archived ssh org-login dirty; do
      src="${dir}/c-${role}.json"
      [[ "${v}" != swap-uid || "${role}" == passkey-login || "${role}" == dirty ]] || continue
      body="${dir}/b-${v}-${role}.json"
      build_body "${v}" "${src}" "${dir}/c-twin.json" "${uid}" "LKRD-TEST" > "${body}" \
        || { fail "${v} on ${role}: the builder failed"; continue; }
      case "${v}" in
        prizm|create-prizm|prizm-uid|create-prizm-uid|borrow-uid)
          has_none "${body}" "${forbidden_prizm}" || fail "${v} on ${role} carries a key Prizm never sends"
          jq -e '(.login // {}) | has("uri") | not' "${body}" >/dev/null || fail "${v} on ${role} carries login.uri" ;;
        *)
          has_none_top "${body}" "${forbidden_echo}" || fail "${v} on ${role} carries a response-only key"
          jq -e '(.login // {}) | has("uri") | not' "${body}" >/dev/null || fail "${v} on ${role} carries login.uri"
          if [[ "${v}" == echo-nokey-uid ]]; then
            jq -e 'has("key") | not' "${body}" >/dev/null || fail "${v} on ${role} still has key"
          else
            jq -e 'has("key")' "${body}" >/dev/null || fail "${v} on ${role} lost key"
          fi
          if [[ "${v}" == echo-noarchived-uid ]]; then
            jq -e 'has("archivedDate") | not' "${body}" >/dev/null || fail "${v} on ${role} still has archivedDate"
          else
            jq -e 'has("archivedDate")' "${body}" >/dev/null || fail "${v} on ${role} lost archivedDate"
          fi ;;
      esac
      # encryptedFor: on every body except the two E1 variants that test its absence.
      case "${v}" in
        prizm|create-prizm) jq -e 'has("encryptedFor") | not' "${body}" >/dev/null || fail "${v} on ${role} has encryptedFor" ;;
        *) jq -e --arg uid "${uid}" '.encryptedFor == $uid' "${body}" >/dev/null || fail "${v} on ${role} lacks encryptedFor" ;;
      esac
      case "${v}" in
        create-prizm|create-prizm-uid|clone-echo-uid) jq -e 'has("id") | not' "${body}" >/dev/null || fail "${v} on ${role} keeps id" ;;
        *) jq -e --slurpfile s "${src}" '.id == $s[0].id' "${body}" >/dev/null || fail "${v} on ${role} lost id" ;;
      esac
      if [[ "${v}" == stale-uid ]]; then
        jq -e '.lastKnownRevisionDate == "LKRD-TEST"' "${body}" >/dev/null || fail "stale-uid lacks lastKnownRevisionDate"
      else
        jq -e 'has("lastKnownRevisionDate") | not' "${body}" >/dev/null || fail "${v} on ${role} has lastKnownRevisionDate"
      fi
    done
  done
  # The swap swaps, and nothing else moves.
  jq -e --slurpfile s "${dir}/c-passkey-login.json" '
      .login.uris[0].uriChecksum == $s[0].login.uris[1].uriChecksum
      and .login.uris[1].uriChecksum == $s[0].login.uris[0].uriChecksum
      and .login.uris[0].uriChecksum != .login.uris[1].uriChecksum
      and ([.login.uris[].uri] == [$s[0].login.uris[].uri])' "${dir}/b-swap-uid-passkey-login.json" >/dev/null \
    || fail "swap-uid did not swap exactly the two checksums"
  # borrow replaces exactly name, notes, username, password and the uris, and nothing else.
  jq -e --slurpfile t "${dir}/c-twin.json" '
      .name == $t[0].name and (has("notes") == ($t[0].notes != null))
      and .login.username == $t[0].login.username and .login.password == $t[0].login.password
      and ([.login.uris[].uri] | all(. == $t[0].login.uris[0].uri))' "${dir}/b-borrow-uid-passkey-login.json" >/dev/null \
    || fail "borrow-uid did not take the donor's ciphertext"
  jq -e -n --slurpfile b "${dir}/b-borrow-uid-passkey-login.json" --slurpfile p "${dir}/b-prizm-uid-passkey-login.json" '
      def rest: del(.name, .notes, .login.username, .login.password, (.login.uris[]? | .uri));
      ($b[0] | rest) == ($p[0] | rest)' >/dev/null || fail "borrow-uid changed more than the listed fields"

  # The Prizm-shaped key sets of the control equal what real Prizm sent in E1(a).
  local line top login uri want_top want_login want_uri
  want_top="$(jq -r 'keys | join(",")' "${dir}/b-prizm-control.json")"
  want_login="$(jq -r '.login | keys | join(",")' "${dir}/b-prizm-control.json")"
  want_uri="$(jq -r '[.login.uris[] | keys[]] | unique | join(",")' "${dir}/b-prizm-control.json")"
  local seen=0
  while IFS= read -r line; do
    [[ "${line}" == \#* || -z "${line}" ]] && continue
    top="$(sed -n 's/.*| top=\([^ |]*\).*/\1/p' <<<"${line}" | tr ',' '\n' | sort | paste -sd, -)"
    login="$(sed -n 's/.*| login=\([^ |]*\).*/\1/p' <<<"${line}" | tr ',' '\n' | sort | paste -sd, -)"
    uri="$(sed -n 's/.*| uri=\([^ |]*\).*/\1/p' <<<"${line}" | tr ',' '\n' | sort | paste -sd, -)"
    seen=$((seen + 1))
    [[ "${top}" == "${want_top}" ]] || fail "control prizm key set differs from real Prizm's E1(a) body (top: ${want_top} vs ${top})"
    [[ "${login}" == "${want_login}" ]] || fail "control prizm login keys differ from real Prizm (${want_login} vs ${login})"
    [[ "${uri}" == "${want_uri}" ]] || fail "control prizm uri keys differ from real Prizm (${want_uri} vs ${uri})"
  done < "${E1A_KEYS}"
  (( seen > 0 )) || fail "no E1(a) key line in ${E1A_KEYS}"

  # --- part 2: every row against the fake server ---
  FAKE_DIR="${dir}/fake"
  mkdir -p "${FAKE_DIR}/store"
  echo 0 > "${FAKE_DIR}/offset"
  echo 0 > "${FAKE_DIR}/clone-n"
  : > "${FAKE_DIR}/reqlog"
  jq -c '.ciphers[]' "${GOLDEN}" | while IFS= read -r line; do
    printf '%s\n' "${line}" > "${FAKE_DIR}/store/$(jq -r .id <<<"${line}").json"
  done
  RIG_EVIDENCE_DIR="${dir}/evidence"
  mkdir -p "${RIG_EVIDENCE_DIR}"
  FIXTURES_DIR="${dir}/fixtures"
  SLEEP_CMD="fake_sleep"
  API_IMPL="fake_api"
  PROFILE_ID="${uid}"
  local repo_stale="${PRIZM_REPO_ROOT}/Prizm/PrizmTests/Fixtures/stale-put-400-1.37.4.json" stale_before=absent
  [[ ! -e "${repo_stale}" ]] || stale_before=present

  run_row() {  # <version> <row function>: runs in a subshell with errexit on, so a die or a failed command is a failure
    local rc=0 ver="$1" fn="$2"
    set +e
    (
      set -e
      VERSION="${ver}" RIG_VERSION="${ver}"
      WORK_DIR="$(mktemp -d "${dir}/work.XXXXXX")"
      cp "${roles_json}" "${RIG_EVIDENCE_DIR}/roles-${ver}.json"
      load_roles
      "${fn}" >/dev/null
    )
    rc=$?
    set -e
    (( rc == 0 )) || fail "row ${fn} on ${ver} exited ${rc}"
  }
  local ver
  for ver in 1.37.4 1.37.3; do
    # Fresh fake data and request log per version, so assertions can be read per version.
    : > "${FAKE_DIR}/reqlog"
    echo 0 > "${FAKE_DIR}/offset"
    jq -c '.ciphers[]' "${GOLDEN}" | while IFS= read -r line; do
      printf '%s\n' "${line}" > "${FAKE_DIR}/store/$(jq -r .id <<<"${line}").json"
    done
    RIG_VERSION="${ver}"
    run_row "${ver}" row_e1
    run_row "${ver}" row_e4
    run_row "${ver}" row_e5
    if [[ "${ver}" == 1.37.4 ]]; then
      run_row "${ver}" row_e2
      run_row "${ver}" row_e7
      run_row "${ver}" row_e8
      run_row "${ver}" row_e9
    fi
    cp "${FAKE_DIR}/reqlog" "${dir}/reqlog.${ver}"
  done
  run_row 1.37.4 row_e6

  local log="${dir}/reqlog.1.37.4" ev="${RIG_EVIDENCE_DIR}"
  # Every body sent to /api/ciphers or /api/ciphers/<id> carries encryptedFor, except the two E1 variants.
  local nouid
  nouid="$(grep -E '^(POST|PUT) /api/ciphers(/[^/ ]+)? ' "${log}" | grep -v '^PUT /api/ciphers/move ' | grep ' uid=no ' | sed 's/.* label=//' | sort | paste -sd, -)"
  [[ "${nouid}" == "post-prizm-without-encryptedFor,put-prizm-without-encryptedFor" ]] \
    || fail "cipher bodies without encryptedFor are '${nouid}', expected exactly the two E1 variants"
  [[ "$(grep -cE '^(POST|PUT) /api/ciphers(/[^/ ]+)? ' "${log}")" -gt 20 ]] || fail "the fake run sent suspiciously few cipher writes"
  # Requests without item data never carry it, and have the bodies Prizm sends.
  local itemless
  itemless="$(grep -E '/(partial|collections|delete|restore|archive|unarchive|attachment)|/move |/api/folders' "${log}" | grep 'uid=yes' || true)"
  [[ -z "${itemless}" ]] || fail "an item-less request carries encryptedFor"
  grep -q '^PUT /api/ciphers/.*/partial uid=no body=favorite,folderId ' "${log}" || fail "/partial body is not {favorite, folderId}"
  grep -q '^PUT /api/ciphers/move uid=no body=folderId,ids ' "${log}" || fail "/move body is not {ids, folderId}"
  grep -q '^PUT /api/ciphers/.*/collections uid=no body=collectionIds ' "${log}" || fail "/collections body is not {collectionIds}"
  grep -q '^POST /api/folders uid=no body=name ' "${log}" || fail "folder body is not {name}"
  grep -q '^POST /api/ciphers/.*/attachment/v2 uid=no body=fileName,fileSize,key ' "${log}" || fail "attachment body is not {key, fileName, fileSize}"
  grep -qE '^PUT /api/ciphers/[^/ ]+/(delete|restore) uid=na body=- ' "${log}" || fail "delete and restore must have no body"
  # E5 order: base write, reference GET, wait, competing write, stale PUT; gap0 has no wait.
  local tokens
  tokens="$(awk '/^SLEEP/ {printf "SLEEP%s ", $2; next} $NF != "label=-" {sub(/^label=/, "", $NF); printf "%s ", $NF; next} $1 == "GET" {printf "GET "}' "${log}")"
  [[ "${tokens}" == *"gap3-base-write GET SLEEP3 gap3-competing-write GET gap3-stale-put GET"* ]] \
    || fail "gap3 order is wrong: ${tokens}"
  [[ "${tokens}" == *"gap0-base-write GET gap0-competing-write GET gap0-stale-put GET"* ]] \
    || fail "gap0 must not wait: ${tokens}"
  # Statuses of the fake match the expectations the rows carry.
  grep -q 'RESULT E5 gap3-stale-put status=400' "${ev}/e5-1.37.4.log" || fail "gap3 stale PUT was not rejected"
  grep -q 'RESULT E5 gap0-stale-put status=200' "${ev}/e5-1.37.4.log" || fail "gap0 stale PUT was not accepted"
  grep -q 'RESULT E5 epoch-stale-put status=400' "${ev}/e5-1.37.4.log" || fail "epoch stale PUT was not rejected"
  grep -q 'RESULT E5 garbage-stale-put status=200' "${ev}/e5-1.37.4.log" || fail "garbage stale PUT was not accepted"
  local mismatch
  for ver in 1.37.4 1.37.3; do
    mismatch="$(grep 'RESULT E1' "${ev}/e1-${ver}.log" | grep 'match=no' || true)"
    [[ -z "${mismatch}" ]] || fail "E1 on the fake ${ver} does not match its own expectations"
  done
  # The stale body goes to the fixtures directory on 1.37.4 only, never to the repo during a selftest.
  if [[ ! -f "${FIXTURES_DIR}/stale-put-400-1.37.4.json" ]] || ! grep -qi 'out of date' "${FIXTURES_DIR}/stale-put-400-1.37.4.json"; then
    fail "the 1.37.4 stale body was not published to the fixtures directory"
  fi
  [[ ! -e "${FIXTURES_DIR}/stale-put-400-1.37.3.json" && -f "${ev}/stale-put-400-1.37.3.json" ]] \
    || fail "the 1.37.3 stale body must stay in the evidence directory"
  local stale_after=absent
  [[ ! -e "${repo_stale}" ]] || stale_after=present
  [[ "${stale_before}" == "${stale_after}" ]] || fail "the selftest created or removed ${repo_stale}"
  # E6 lines per field, and the rows left evidence.
  for name in revisionDate creationDate deletedDate archivedDate login.passwordRevisionDate 'passwordHistory\[\].lastUsedDate' 'login.fido2Credentials\[\].creationDate'; do
    grep -q "RESULT E6 ${name} " "${ev}/e6-1.37.4.log" || fail "no RESULT E6 line for ${name}"
  done
  for name in e2 e4 e7 e8 e9; do
    grep -q "RESULT ${name^^} " "${ev}/${name}-1.37.4.log" || fail "row ${name} left no RESULT line"
  done
  # Evidence never holds an EncString, a token or an email.
  if grep -hE '[0-9]\.[A-Za-z0-9+/=]{20,}\||eyJ|@example\.com' "${ev}"/*.log >/dev/null 2>&1; then
    fail "evidence holds an EncString, a token or an email"
  fi

  # D-15 fallback: e2 and e9 skip with the phrase and send nothing.
  printf 'd15-outcome: fallback\nauthoring-digest: sha256:1234abcd5678ef90\n' > "${dir}/provenance-fallback.md"
  local saved_prov="${PROVENANCE}" before_n
  PROVENANCE="${dir}/provenance-fallback.md"
  before_n="$(wc -l < "${FAKE_DIR}/reqlog")"
  run_row 1.37.4 row_e2
  run_row 1.37.4 row_e9
  PROVENANCE="${saved_prov}"
  [[ "$(wc -l < "${FAKE_DIR}/reqlog")" == "${before_n}" ]] || fail "a skipped row sent requests"
  grep -q 'RESULT E2 skipped keyed fixture not reproducible with extension 2026.10.0 and the injected flag on 1.37.3 sha256:1234abcd' "${ev}/e2-1.37.4.log" \
    || fail "E2 skip line lacks the D-15 phrase"
  grep -q 'RESULT E9 skipped keyed fixture not reproducible' "${ev}/e9-1.37.4.log" || fail "E9 skip line lacks the D-15 phrase"

  # The guard: a cipher body without encryptedFor is refused outside the E1 variants.
  (
    set +e
    VERSION=1.37.4 WORK_DIR="${dir}/work.guard"; mkdir -p "${WORK_DIR}"
    NO_UID_OK=0
    jq -n '{id: "x", type: 1}' > "${WORK_DIR}/nouid.json"
    ( api PUT /api/ciphers/x "${WORK_DIR}/nouid.json" ) >/dev/null 2>&1
  ) && fail "api() sent a cipher body without encryptedFor"

  if (( failures > 0 )); then
    echo "experiment selftest FAILED: ${failures} case(s)" >&2
    return 1
  fi
  echo "experiment selftest OK"
}

# --- main ----------------------------------------------------------------------------------------

main() {
  local row="" run_selftest=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) VERSION="${2:-}"; shift 2 || die "--version needs a value" ;;
      --selftest) run_selftest=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) usage >&2; die "unknown option: $1" ;;
      *) [[ -z "${row}" ]] || die "one row at a time (got '${row}' and '$1')"; row="$1"; shift ;;
    esac
  done

  if (( run_selftest )); then selftest; return; fi
  [[ -n "${row}" ]] || { usage >&2; die "name a row, or use --selftest"; }

  case "${row}" in
    summary) row_summary; return ;;
    e6)
      VERSION=1.37.4 RIG_VERSION=1.37.4
      RIG_EVIDENCE_DIR="${PRIZM_REPO_ROOT}/dev-vault/evidence"
      row_e6
      return ;;
    roles|e1|e2|e4|e5|e7|e8|e9) ;;
    *) usage >&2; die "unknown row '${row}'" ;;
  esac

  [[ -n "${VERSION}" ]] || { usage >&2; die "--version is required for ${row}"; }
  rig_init "${VERSION}"
  WORK_DIR="$(mktemp -d "${RIG_STATE_DIR}/exp.XXXXXX")"
  trap cleanup EXIT
  [[ "${row}" == roles ]] || load_roles
  "row_${row}"
  if (( ROW_FAILED != 0 )); then die "row ${row} finished with a failure (see the RESULT lines)."; fi
}

main "$@"
