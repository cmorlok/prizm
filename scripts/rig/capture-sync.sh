#!/usr/bin/env bash
# Captures, scrubs and verifies the golden /api/sync fixture. Fail-closed: every check is named,
# every failure prints "FAIL <check>", and any failure ends in a non-zero exit.
#
#   scripts/rig/capture-sync.sh --version <1.37.3|1.37.4> --out <path>   (container only)
#   scripts/rig/capture-sync.sh --verify <file>                          (offline)
#   scripts/rig/capture-sync.sh --selftest                               (offline)
#
# --version/--out  GET /api/sync?excludeDomains=true with Prizm's identification headers, scrub it
#                  with scripts/rig/scrub.jq, run every check against the raw and the scrubbed
#                  document, and only then move the result to <path>. The raw response lives in a
#                  mode-600 file in the probe state dir (outside the repo) that an EXIT trap
#                  deletes (D-11); the output is built in a temp file, so a failed or interrupted
#                  run never creates or overwrites <path>.
# --verify         The checks that need neither the raw document nor the network: used on the
#                  stale-PUT 400 body (plan 06) and before the fixture commit (plan 07).
# --selftest       Builds a synthetic Vaultwarden-shaped document, proves the scrub and all checks
#                  pass on it, and proves every check fails on a document that breaks its rule.
#                  Ends in "capture-sync selftest OK".
#
# Checks on every document (--verify, and part of --version): parses, no-jwt, tokens-scrubbed,
# no-ipv4, urls-local-only, uuids-relabelled, attachments, org-names, secrets-absent (password,
# master key and server hash, with the iteration count from the "kdf:" line of
# dev-vault/evidence/provenance.md), access-token-absent (only when a cached token file exists),
# email. Extra checks against the raw document (--version only): structure-identical,
# encstrings-identical, timestamps-identical, raw-ids-gone, has-ssh-cipher.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}"; }

FIXTURE_EMAIL="prizm-fixture@example.com"
ORG_PLACEHOLDER="Prizm Fixture Org"
SCRUB_JQ="${RIG_LIB_DIR}/scrub.jq"
PROVENANCE="${PRIZM_REPO_ROOT}/dev-vault/evidence/provenance.md"

# jq (Oniguruma) regexes, passed with --arg. UUID_RE must stay in step with uuid_re in scrub.jq.
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
DUMMY_UUID_RE='^00000000-0000-4000-8000-[0-9a-f]{12}$'
ENC_RE='^[0-9]+\.[A-Za-z0-9+/=]+(\|[A-Za-z0-9+/=]+)*$'
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T'

# Where the secret-absence checks look. The selftest points them at throwaway fakes.
CHECK_ENV_FILE="${PRIZM_REPO_ROOT}/dev-vault/.env"
CHECK_STATE_DIR="${TMPDIR:-/tmp}/prizm-rig-$(id -u)"
CHECK_ITERATIONS=""   # empty: read the "kdf:" line of provenance.md

FAILED=0

# check <name> <command...>: runs the command with all output discarded (a failing check must never
# echo document content), prints "PASS <name>" or "FAIL <name>" and counts the failures.
check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'PASS %s\n' "${name}"
  else
    printf 'FAIL %s\n' "${name}"
    FAILED=$((FAILED + 1))
  fi
}

# --- checks on one document (the scrubbed one) -------------------------------------------------

c_parses() { jq -e . "$1"; }

# A signed JWT starts with eyJ ({" in base64). Text-level on purpose: keys and values alike.
# `|| true` inside the substitution: grep exits 1 on no match, which is the good case.
c_no_jwt() { local hit; hit="$(grep -c 'eyJ' "$1" || true)"; [[ "${hit}" == 0 ]]; }

c_tokens_scrubbed() {
  local bad
  bad="$(grep -oE 'token=[^"&[:space:]\\]*' "$1" | grep -vx 'token=SCRUBBED' || true)"
  [[ -z "${bad}" ]]
}

c_no_ipv4() {
  local bad
  bad="$(grep -oE '(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}($|[^0-9.])' "$1" || true)"
  [[ -z "${bad}" ]]
}

c_urls_local_only() {
  jq -e '[.. | strings | scan("https?://[^\\s\"]*")] | all(test("^https://localhost:8443([/?#]|$)"))' "$1"
}

# Every UUID-shaped string, in any case, must be one of the fixed dummies.
c_uuids_relabelled() {
  jq -e --arg re "${UUID_RE}" --arg dummy "${DUMMY_UUID_RE}" \
    '[.. | strings | match($re; "g").string] | all(ascii_downcase | test($dummy))' "$1"
}

# Attachment ids are in the a<19 digits> form and the url is exactly host/attachments/<cipher id>/<id>?token=SCRUBBED.
c_attachments() {
  jq -e '[.ciphers[]? | . as $c | $c.attachments[]?
          | (.id | test("^a[0-9]{19}$"))
            and (.url == "https://localhost:8443/attachments/" + $c.id + "/" + .id + "?token=SCRUBBED")]
         | all' "$1"
}

c_org_names() {
  jq -e --arg n "${ORG_PLACEHOLDER}" \
    '[.organizations[]?.name, .profile.organizations[]?.name, .profile.organizationsNew[]?.name] | all(. == $n)' "$1"
}

c_secrets_absent() {
  local iterations="${CHECK_ITERATIONS}"
  if [[ -z "${iterations}" ]]; then
    iterations="$(sed -n 's/^kdf:.* \([0-9][0-9]*\)[[:space:]]*$/\1/p' "${PROVENANCE}" 2>/dev/null | head -n 1)"
  fi
  [[ "${iterations}" =~ ^[0-9]+$ ]] || return 1
  python3 -I "${RIG_TOKEN_FORM}" absent "${CHECK_ENV_FILE}" "${iterations}" "$1"
}

# The cached access token (line 2 of each token file) must not occur in the document. The token is
# read into a variable and piped to grep's pattern list; it is never printed.
c_access_token_absent() {
  local file="$1" token_file token
  shopt -s nullglob
  for token_file in "${CHECK_STATE_DIR}"/*.token; do
    token="$(sed -n 2p "${token_file}")"
    [[ -n "${token}" ]] || return 1   # an unreadable token file must not pass vacuously
    if printf '%s\n' "${token}" | grep -qF -f - "${file}"; then return 1; fi
  done
  shopt -u nullglob
  return 0
}

c_email() { jq -e --arg e "${FIXTURE_EMAIL}" '(.profile == null) or (.profile.email == $e)' "$1"; }

# verify_checks <file>: every check that needs only the document itself. Adds to FAILED.
verify_checks() {
  local file="$1"
  check parses c_parses "${file}"
  check no-jwt c_no_jwt "${file}"
  check tokens-scrubbed c_tokens_scrubbed "${file}"
  check no-ipv4 c_no_ipv4 "${file}"
  check urls-local-only c_urls_local_only "${file}"
  check uuids-relabelled c_uuids_relabelled "${file}"
  check attachments c_attachments "${file}"
  check org-names c_org_names "${file}"
  check secrets-absent c_secrets_absent "${file}"
  check access-token-absent c_access_token_absent "${file}"
  check email c_email "${file}"
}

# --- checks that compare the scrubbed document with the raw one --------------------------------

# Same paths: the scrub changed values only, never the shape.
c_structure_identical() {
  [[ "$(jq -c '[paths]' "$1")" == "$(jq -c '[paths]' "$2")" ]]
}

# The sorted multiset of strings matching <regex> must not change: EncStrings and timestamps pass
# through the scrub untouched.
multiset_identical() {
  # shellcheck disable=SC2016  # $re is a jq variable (--arg), not a shell expansion
  local re="$1" raw="$2" scrubbed="$3" filter='[.. | strings | select(test($re))] | sort'
  [[ "$(jq -c --arg re "${re}" "${filter}" "${raw}")" == "$(jq -c --arg re "${re}" "${filter}" "${scrubbed}")" ]]
}

# None of the raw ids, attachment ids or plaintext names may survive in the scrubbed text. The
# patterns go to a mode-600 file in the state dir; `ids_file` is set by the caller for cleanup.
c_raw_ids_gone() {
  local raw="$1" scrubbed="$2"
  jq -r --arg re "${UUID_RE}" --arg org "${ORG_PLACEHOLDER}" '
      ([.. | strings | match($re; "g").string | ascii_downcase] | unique[]),
      ([.ciphers[]?.attachments[]?.id | select(. != null)][]),
      ([.profile.name, (.organizations[]?.name), (.profile.organizations[]?.name), (.profile.organizationsNew[]?.name)]
        | map(select(. != null and length >= 4 and . != $org and . != "Prizm Fixture"))[])' \
    "${raw}" > "${ids_file}"
  [[ -s "${ids_file}" ]] || return 1   # a document without ids is not a sync response
  if grep -qiF -f "${ids_file}" "${scrubbed}"; then return 1; fi
}

c_has_ssh_cipher() { jq -e '[.ciphers[]? | select(.type == 5)] | length >= 1' "$1"; }
c_has_profile() { jq -e '.profile != null and ((.ciphers // []) | length) > 0' "$1"; }

# capture_checks <raw> <scrubbed>: verify_checks plus the raw-document comparisons.
capture_checks() {
  local raw="$1" scrubbed="$2"
  verify_checks "${scrubbed}"
  check structure-identical c_structure_identical "${raw}" "${scrubbed}"
  check encstrings-identical multiset_identical "${ENC_RE}" "${raw}" "${scrubbed}"
  check timestamps-identical multiset_identical "${TS_RE}" "${raw}" "${scrubbed}"
  check raw-ids-gone c_raw_ids_gone "${raw}" "${scrubbed}"
  # A type-5 cipher proves the Bitwarden-Client-Version header reached the server (Pitfall 6).
  check has-ssh-cipher c_has_ssh_cipher "${scrubbed}"
  check has-profile c_has_profile "${scrubbed}"
}

scrub() { jq --arg email "${FIXTURE_EMAIL}" -f "${SCRUB_JQ}" "$1"; }

# --- modes ---------------------------------------------------------------------------------------

raw_file="" tmp_file="" ids_file="" partial_file=""
cleanup() { rm -f "${raw_file}" "${tmp_file}" "${ids_file}" "${partial_file}"; }

capture() {
  local version="$1" out="$2" status
  rig_init "${version}"
  rig_prelogin   # also fails closed unless the account uses PBKDF2-SHA256
  CHECK_ITERATIONS="${RIG_KDF_ITERATIONS}"
  CHECK_STATE_DIR="${RIG_STATE_DIR}"
  CHECK_ENV_FILE="${RIG_ENV_FILE}"

  raw_file="${RIG_STATE_DIR}/sync-raw-${RIG_VERSION}.json"
  ids_file="${RIG_STATE_DIR}/sync-ids-${RIG_VERSION}.txt"
  tmp_file="${RIG_STATE_DIR}/sync-golden-${RIG_VERSION}.json"
  trap cleanup EXIT

  status="$(rig_api GET "/api/sync?excludeDomains=true" "${raw_file}")" || exit 1
  [[ "${status}" == 200 ]] || die "GET /api/sync answered HTTP ${status}."

  # umask 077: the scrubbed temp file is as private as the raw one until every check has passed.
  ( umask 077; scrub "${raw_file}" > "${tmp_file}" ) \
    || { echo "FAIL scrub"; die "the scrub refused the document (see the jq message above)."; }

  FAILED=0
  capture_checks "${raw_file}" "${tmp_file}"
  if (( FAILED > 0 )); then
    die "${FAILED} check(s) failed; ${out} was not written."
  fi

  # Same directory as the target, then rename: the rename is atomic, the copy across filesystems
  # (state dir to repo) is not, and the target must never be seen half written.
  mkdir -p "$(dirname "${out}")"
  partial_file="$(mktemp "$(dirname "${out}")/.$(basename "${out}").XXXXXX")"
  cp "${tmp_file}" "${partial_file}"
  chmod 644 "${partial_file}"
  mv -f "${partial_file}" "${out}"
  partial_file=""
  echo "wrote ${out} ($(jq '.ciphers | length' "${out}") ciphers, $(jq '[.ciphers[] | select(.type == 5)] | length' "${out}") ssh)"
}

verify() {
  local file="$1"
  [[ -f "${file}" ]] || die "${file} does not exist."
  FAILED=0
  verify_checks "${file}"
  (( FAILED == 0 )) || die "${FAILED} check(s) failed for ${file}."
  echo "verify OK ${file}"
}

# A synthetic Vaultwarden-shaped document: two ciphers (one in a folder with an attachment, one in
# an organization and collection), one SSH cipher, real-looking plaintext names and a fake JWT.
# Every EncString is made up; nothing here comes from the rig.
synthetic_doc() {
  jq -n --arg email "${FIXTURE_EMAIL}" '
    def enc($n): "2.ZmFrZWl2\($n)==|ZmFrZWN0\($n)==|ZmFrZW1hYw==";
    def uid($n): "\("abcdef0123456789"[0:8])-1234-4abc-8def-\("00000000000" + ($n | tostring))[-12:]";
    uid(1) as $user | uid(2) as $org | uid(3) as $orgUser | uid(4) as $folder | uid(5) as $coll
    | uid(6) as $c1 | uid(7) as $c2 | uid(8) as $c3 | uid(9) as $stamp
    | {object: "sync",
       profile: {id: $user, email: $email, name: "Real Person", securityStamp: $stamp, key: enc(1),
                 privateKey: enc(2), accountKeys: {publicKeyEncryptionKeyPair: {wrappedPrivateKey: enc(3)}},
                 creationDate: "2026-10-26T10:00:00.123456Z",
                 organizations: [{id: $org, userId: $user, organizationUserId: $orgUser, name: "Acme Corp Secrets", key: enc(4)}],
                 organizationsNew: [{id: $org, userId: $user, organizationUserId: $orgUser, name: "Acme Corp Secrets", key: enc(4)}]},
       userDecryption: {masterPasswordUnlock: {salt: $email, kdf: {kdfType: 0, iterations: 5000},
                                               masterKeyEncryptedUserKey: enc(5)}},
       folders: [{id: $folder, name: enc(6), revisionDate: "2026-10-26T10:01:00.000000Z"}],
       collections: [{id: $coll, organizationId: $org, name: enc(7)}],
       ciphers: [
         {id: $c1, type: 1, folderId: $folder, organizationId: null, name: enc(8), key: enc(9),
          revisionDate: "2026-10-26T10:02:00.111111Z", creationDate: "2026-10-26T10:02:00.111111Z",
          collectionIds: [],
          login: {username: enc(10), password: enc(11), uris: [{uri: enc(12), uriChecksum: enc(13)}]},
          attachments: [{id: "0123456789abcdef0123", fileName: enc(14), key: enc(15), size: "24",
                         sizeName: "24 Bytes", object: "attachment",
                         url: "https://localhost:8443/attachments/\($c1)/0123456789abcdef0123?token=eyJhbGciOiJIUzI1NiJ9.ZmFrZXBheWxvYWQ.ZmFrZXNpZw"}]},
         {id: $c2, type: 1, folderId: null, organizationId: $org, name: enc(16), key: enc(17),
          revisionDate: "2026-10-26T10:03:00.222222Z", creationDate: "2026-10-26T10:03:00.222222Z",
          collectionIds: [$coll], attachments: [],
          login: {username: enc(18), password: enc(19), uris: []}},
         {id: $c3, type: 5, folderId: null, organizationId: null, name: enc(20), key: enc(21),
          revisionDate: "2026-10-26T10:04:00.333333Z", creationDate: "2026-10-26T10:04:00.333333Z",
          collectionIds: [], attachments: [],
          sshKey: {privateKey: enc(22), publicKey: enc(23), keyFingerprint: enc(24)}}]}'
}

selftest() {
  local dir failures=0
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: the directory name is fixed
  trap "rm -rf '${dir}'" EXIT

  # Fake secrets for the secret-absence checks: a made-up account, never the rig's.
  printf 'PRIZM_RIG_EMAIL=selftest@example.com\nPRIZM_RIG_PASSWORD=selftest-password-not-a-secret\n' > "${dir}/env"
  mkdir "${dir}/state"
  CHECK_ENV_FILE="${dir}/env"
  CHECK_STATE_DIR="${dir}/state"
  CHECK_ITERATIONS=5000
  ids_file="${dir}/ids.txt"

  synthetic_doc > "${dir}/raw.json"
  scrub "${dir}/raw.json" > "${dir}/scrubbed.json" \
    || { echo "selftest FAILED: the scrub rejected the synthetic document" >&2; return 1; }

  fail() { echo "selftest FAILED: $1" >&2; failures=$((failures + 1)); }

  # 1. The scrub and all checks pass on the synthetic document.
  local out status=0
  FAILED=0
  out="$(capture_checks "${dir}/raw.json" "${dir}/scrubbed.json")" || status=$?
  [[ "${out}" != *FAIL* ]] || fail "capture checks failed on the scrubbed synthetic document: $(grep FAIL <<<"${out}" | tr '\n' ' ')"
  FAILED=0

  # 2. The scrub is deterministic and keeps the relations.
  scrub "${dir}/raw.json" > "${dir}/scrubbed2.json"
  cmp -s "${dir}/scrubbed.json" "${dir}/scrubbed2.json" || fail "the scrub is not deterministic"
  jq -e '(.ciphers[0].folderId == .folders[0].id)
         and (.ciphers[1].organizationId == .profile.organizations[0].id)
         and (.ciphers[1].organizationId == .collections[0].organizationId)
         and (.ciphers[1].collectionIds[0] == .collections[0].id)
         and (.profile.organizations[0].userId == .profile.id)
         and (.profile.organizationsNew[0].id == .profile.organizations[0].id)
         and (.ciphers[0].attachments[0].url
              == "https://localhost:8443/attachments/\(.ciphers[0].id)/\(.ciphers[0].attachments[0].id)?token=SCRUBBED")
         and (.profile.name == "Prizm Fixture") and (.profile.email == "prizm-fixture@example.com")' \
    "${dir}/scrubbed.json" >/dev/null || fail "the scrub broke a relation or a placeholder"
  scrub_wrong_email() { jq --arg email "someone@example.com" -f "${SCRUB_JQ}" "${dir}/raw.json"; }
  if scrub_wrong_email >/dev/null 2>&1; then fail "the scrub accepted a different account email"; fi

  # 3. The verify checks fail on the unscrubbed document, each by name.
  status=0
  out="$(verify_checks "${dir}/raw.json")" || status=$?
  FAILED=0
  local name
  for name in no-jwt tokens-scrubbed uuids-relabelled attachments org-names; do
    [[ "${out}" == *"FAIL ${name}"* ]] || fail "verify did not fail '${name}' on the unscrubbed document"
  done

  # 4. Each check bites on a scrubbed document that breaks its rule.
  printf '1\nselftest-access-token-value\n' > "${dir}/state/1.37.4.token"
  # bite_verify <check> <jq filter over scrubbed.json>: the named check must print FAIL.
  bite_verify() {
    jq "$2" "${dir}/scrubbed.json" > "${dir}/mutant.json"
    out="$(verify_checks "${dir}/mutant.json")" || true
    FAILED=0
    [[ "${out}" == *"FAIL $1"* ]] || fail "check '$1' did not bite on: $2"
  }
  # bite_capture <check> <jq filter over scrubbed.json>: same for the raw-comparison checks.
  bite_capture() {
    jq "$2" "${dir}/scrubbed.json" > "${dir}/mutant.json"
    out="$(capture_checks "${dir}/raw.json" "${dir}/mutant.json")" || true
    FAILED=0
    [[ "${out}" == *"FAIL $1"* ]] || fail "check '$1' did not bite on: $2"
  }
  printf '{"broken": ' > "${dir}/corrupt.json"
  out="$(verify_checks "${dir}/corrupt.json")" || true
  FAILED=0
  [[ "${out}" == *"FAIL parses"* ]] || fail "check 'parses' did not bite on a corrupt file"
  bite_verify no-jwt            '.profile.name = "eyJabc"'
  bite_verify tokens-scrubbed   '.ciphers[0].attachments[0].url |= sub("SCRUBBED"; "abc")'
  bite_verify no-ipv4           '.profile.name = "host 10.1.2.3 here"'
  bite_verify urls-local-only   '.profile.name = "http://other.example/a"'
  bite_verify urls-local-only   '.profile.name = "https://localhost:8443.evil.example/a"'
  bite_verify uuids-relabelled  '.ciphers[0].id = "123e4567-e89b-42d3-a456-426614174000"'
  bite_verify uuids-relabelled  '.profile.id = "123E4567-E89B-42D3-A456-426614174000"'
  bite_verify attachments       '.ciphers[0].attachments[0].id = "0123456789abcdef0123"'
  bite_verify org-names         '.profile.organizationsNew[0].name = "Acme Corp Secrets"'
  bite_verify org-names         '.profile.organizations[0].name = "Acme Corp Secrets"'
  bite_verify secrets-absent    '.profile.name = "selftest-password-not-a-secret"'
  bite_verify access-token-absent '.profile.name = "selftest-access-token-value"'
  bite_verify email             '.profile.email = "other@example.com"'
  # The scrubbed synthetic document itself is clean even with the token file present.
  out="$(verify_checks "${dir}/scrubbed.json")" || true
  FAILED=0
  [[ "${out}" != *FAIL* ]] || fail "the clean scrubbed document failed verify with a token file present"

  bite_capture encstrings-identical '.ciphers[0].login.password = "2.ZmFrZWl2MTE=|ZmFrZWN0MTE=|ZmFrZW1hYw=="'
  bite_capture timestamps-identical '.ciphers[0].revisionDate = "2026-10-26T10:02:00.111112Z"'
  bite_capture structure-identical  'del(.ciphers[0].login.uris[0].uriChecksum)'
  bite_capture raw-ids-gone         '.ciphers[1].folderId = "abcdef01-1234-4abc-8def-000000000004"'
  bite_capture raw-ids-gone         '.profile.name = "Real Person"'
  bite_capture raw-ids-gone         '.ciphers[0].notes = "0123456789abcdef0123"'
  bite_capture has-ssh-cipher       'del(.ciphers[] | select(.type == 5))'
  bite_capture has-profile          'del(.profile)'

  # 5. The stale-PUT 400 body (no profile, no ciphers) passes verify, and without a usable
  # iteration count the secret check fails closed instead of passing vacuously.
  printf '{"message":"The client copy of this cipher is out of date. Resync the client and try again.","object":"error"}\n' > "${dir}/stale.json"
  out="$(verify_checks "${dir}/stale.json")" || true
  FAILED=0
  [[ "${out}" != *FAIL* ]] || fail "a plain error body failed verify: $(grep FAIL <<<"${out}" | tr '\n' ' ')"
  CHECK_ITERATIONS="" PROVENANCE="${dir}/no-provenance.md" out="$(verify_checks "${dir}/stale.json")" || true
  FAILED=0
  [[ "${out}" == *"FAIL secrets-absent"* ]] || fail "secrets-absent passed without an iteration count"

  if (( failures > 0 )); then
    echo "capture-sync selftest FAILED: ${failures} case(s)" >&2
    return 1
  fi
  echo "capture-sync selftest OK"
}

main() {
  local version="" out="" verify_file="" mode=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="${2:-}"; mode="${mode:-capture}"; shift 2 || die "--version needs a value" ;;
      --out) out="${2:-}"; shift 2 || die "--out needs a value" ;;
      --verify) verify_file="${2:-}"; mode=verify; shift 2 || die "--verify needs a file" ;;
      --selftest) mode=selftest; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done

  case "${mode}" in
    selftest) selftest ;;
    verify) [[ -n "${verify_file}" ]] || die "--verify needs a file"; verify "${verify_file}" ;;
    capture)
      [[ -n "${version}" && -n "${out}" ]] || { usage >&2; die "--version and --out are both required"; }
      capture "${version}" "${out}" ;;
    *) usage >&2; die "choose --version/--out, --verify or --selftest" ;;
  esac
}

main "$@"
