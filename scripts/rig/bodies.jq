# Request-body builders for the Vaultwarden experiment rows (Phase 1 plan 05). jq module:
#
#   jq -L scripts/rig --arg uid <profile.id> --arg lkrd "" --slurpfile donor <cipher.json> \
#      'include "bodies"; variant("prizm-uid"; $uid; $donor[0]; $lkrd)' <cipher.json>
#
# Security goal: none of this touches a secret. The probes work on ciphertext the server already
# returned, so no key and no AES is needed (research Pattern 3): the variable under test is which
# keys a body carries, not what they decrypt to. Nothing here decrypts, encrypts or invents an
# EncString; the only values it ever copies are EncStrings taken from the fixture itself.
#
# Two body families, both derived from one cipher object (a GET /api/ciphers/<id> or a /api/sync
# element):
#
#   prizm_body  what real Prizm sends today: the keys RawCipher and CipherMapper.toRawCipher encode
#               (Prizm/Data/Network/Models/RawCipher.swift). Synthesized Encodable omits nil
#               optionals, so it never carries key, passwordHistory, archivedDate, fido2Credentials,
#               uriChecksum, encryptedFor or lastKnownRevisionDate. Checked against real Prizm: the
#               E1(a) PUT sent exactly collectionIds, favorite, id, login (password, uris,
#               username), name, reprompt, type for the control item, with uri items carrying only
#               uri (dev-vault/evidence/e1a-body-keys.txt); no difference to this builder, see
#               scripts/rig/experiment.sh --selftest, which compares them.
#   echo_body   the server's own record sent back: the cipher minus the response-only keys, so a
#               full-fidelity client would not lose data. It never carries data or partialData (the
#               official server stores a non-blank request "data" verbatim and ignores the typed
#               fields; Vaultwarden never sends it) nor the legacy login.uri (the official server
#               appends it to uris). It keeps key and archivedDate even when null, because their
#               absence is exactly what E2 and E4 test.
#
# Neither builder adds encryptedFor. A required field of every cipher create and full update body
# on 1.37.4 (CipherData.encrypted_for; missing means 422), it is added per request by with_uid,
# which experiment.sh applies to every POST or PUT to /api/ciphers and /api/ciphers/<id>; only the
# two E1 variants that test its absence leave it out. Requests without item data (/partial, /move,
# /collections, delete, restore, attachments, folders) never carry it, like Prizm.

def drop_nulls: with_entries(select(.value != null));

def prizm_login:
  {username, password, totp, uris: (.uris // [] | map({uri, match} | drop_nulls))} | drop_nulls;

def prizm_body:
  {id, organizationId, folderId, type, name, notes, favorite, reprompt,
   login: (if .login then (.login | prizm_login) else null end),
   card, identity, secureNote,
   # keyFingerprint is sent nil today (toRawSSHKey).
   sshKey: (if .sshKey then (.sshKey | {privateKey, publicKey}) else null end),
   fields: (if ((.fields // []) | length) > 0
            then [.fields[] | {type, name, value, linkedId} | drop_nulls]
            else null end),
   collectionIds: (.collectionIds // [])}
  | drop_nulls;

def echo_body:
  del(.object, .edit, .viewPassword, .permissions, .organizationUseTotp, .attachments,
      .revisionDate, .creationDate, .deletedDate, .login?.uri, .data, .partialData)
  | with_entries(select(.value != null or .key == "key" or .key == "archivedDate"));

def with_uid($uid): .encryptedFor = $uid;
def with_lkrd($d): .lastKnownRevisionDate = $d;
def without($k): del(.[$k]);
def for_create: del(.id);

# Swaps login.uris[0].uriChecksum and login.uris[1].uriChecksum (E9).
def swap_first_two_checksums:
  if ((.login.uris // []) | length) < 2
  then error("swap_first_two_checksums needs a login with two uris")
  else .login.uris[0].uriChecksum as $a
       | .login.uris[1].uriChecksum as $b
       | .login.uris[0].uriChecksum = $b
       | .login.uris[1].uriChecksum = $a
  end;

# Replaces name, notes, login.username, login.password and every login.uris[].uri with the
# donor's EncStrings (E2 ii): the donor is the unkeyed twin, whose ciphertext is encrypted with
# the vault key, so a keyless body that borrows it stays readable without any crypto here. Every
# other key is left alone; a donor without notes removes the body's notes (they would be
# ciphertext of the wrong key). The donor's uris are used round-robin.
def borrow($donor):
  ($donor.login.uris // []) as $d
  | .name = $donor.name
  | (if $donor.notes != null then .notes = $donor.notes else del(.notes) end)
  | if .login == null then .
    else .login.username = $donor.login.username
      | .login.password = $donor.login.password
      | (if ($d | length) > 0
         then .login.uris |= (to_entries | map(.value.uri = $d[.key % ($d | length)].uri | .value))
         else . end)
    end;

# Variant names used by experiment.sh. The source cipher is the input; $donor is the cipher whose
# EncStrings are borrowed (the twin); $lkrd is a raw lastKnownRevisionDate string.
#   prizm, create-prizm                      Prizm-shaped, without encryptedFor (E1 only)
#   prizm-uid, create-prizm-uid              Prizm-shaped with encryptedFor
#   echo-uid                                 echo body (E4 control, E5 writes, E7)
#   echo-nokey-uid, echo-noarchived-uid      echo body minus key (E2 i) or archivedDate (E4)
#   clone-echo-uid                           echo body without id, for POST (E2 ii, E7, E9)
#   borrow-uid                               Prizm-shaped body that borrows the donor's ciphertext
#   swap-uid                                 echo body with the first two uriChecksums swapped
#   stale-uid                                echo body with lastKnownRevisionDate = $lkrd
def variant($name; $uid; $donor; $lkrd):
  if   $name == "prizm"                  then prizm_body
  elif $name == "create-prizm"           then prizm_body | for_create
  elif $name == "prizm-uid"              then prizm_body | with_uid($uid)
  elif $name == "create-prizm-uid"       then prizm_body | for_create | with_uid($uid)
  elif $name == "echo-uid"               then echo_body | with_uid($uid)
  elif $name == "echo-nokey-uid"         then echo_body | without("key") | with_uid($uid)
  elif $name == "echo-noarchived-uid"    then echo_body | without("archivedDate") | with_uid($uid)
  elif $name == "clone-echo-uid"         then echo_body | for_create | with_uid($uid)
  elif $name == "borrow-uid"             then prizm_body | borrow($donor) | with_uid($uid)
  elif $name == "swap-uid"               then echo_body | swap_first_two_checksums | with_uid($uid)
  elif $name == "stale-uid"              then echo_body | with_uid($uid) | with_lkrd($lkrd)
  else error("unknown variant \($name)") end;

# The variants that deliberately carry no encryptedFor.
def variants_without_uid: ["prizm", "create-prizm"];
def all_variants:
  ["prizm", "create-prizm", "prizm-uid", "create-prizm-uid", "echo-uid", "echo-nokey-uid",
   "echo-noarchived-uid", "clone-echo-uid", "borrow-uid", "swap-uid", "stale-uid"];
