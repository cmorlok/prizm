# Role assignment and secret-free summary for the fixture ciphers of a Vaultwarden /api/sync document.
#
#   jq -L scripts/rig 'include "select"; roles'            < sync.json   # role -> cipher id
#   jq -L scripts/rig 'include "select"; cipher_summary'   < sync.json   # one object per cipher
#
# Names of the fixture items are ciphertext, so roles are assigned by structure only. The unkeyed
# control and its twin are two plain personal logins; they are told apart by creationDate and then
# id. A tie is an error, not a guess: a wrong control/twin pairing would make a later experiment
# edit the wrong item without anyone noticing.
#
# Precedence, first match wins:
#   archived       archivedDate set (any type)
#   ssh            type 5
#   org-login      organizationId set and type 1
#   passkey-login  personal login with at least one fido2 credential
#   control, twin  the first two remaining plain personal logins (no attachment), oldest first
#   extra          everything else
# Only structure and counts come out of cipher_summary; no EncString value is ever copied.

def fixture_logins:
  [.ciphers[]?
   | select(.type == 1
            and .organizationId == null
            and .archivedDate == null
            and (((.login.fido2Credentials // []) | length) == 0)
            and (((.attachments // []) | length) == 0))]
  | sort_by([.creationDate, .id]);

# Control-shaped logins in role order; fails on ties that would make the order a guess.
def ordered_logins:
  fixture_logins as $logins
  | if ($logins | length) >= 2 and $logins[0].creationDate == $logins[1].creationDate
    then error("ambiguous: equal creationDate")
    # The second and third also tie when the twin could be either of them.
    elif ($logins | length) >= 3 and $logins[1].creationDate == $logins[2].creationDate
    then error("ambiguous: equal creationDate")
    else $logins end;

# [{id, role}] for every cipher, in the sync document's order.
def assignments:
  ordered_logins as $logins
  | ($logins | map(.id)) as $ids
  | [.ciphers[]?
     | . as $c
     | {id: .id,
        role: (if .archivedDate != null then "archived"
               elif .type == 5 then "ssh"
               elif .organizationId != null and .type == 1 then "org-login"
               elif .type == 1 and .organizationId == null
                    and ((.login.fido2Credentials // []) | length) > 0 then "passkey-login"
               elif ($ids | index($c.id)) == 0 then "control"
               elif ($ids | index($c.id)) == 1 then "twin"
               else "extra" end)}];

# role -> cipher id (the first cipher of that role, in sync order). `extra` is included when present.
def roles:
  [assignments[] | {key: .role, value: .id}]
  | reverse | from_entries;

def present_ssh_fields:
  [(.sshKey // {}) | to_entries[]
   | select(.key | IN("privateKey", "publicKey", "keyFingerprint"))
   | select(.value != null and .value != "")
   | .key];

def cipher_summary:
  (assignments | map({key: .id, value: .role}) | from_entries) as $role_of
  | [.ciphers[]?
     | {id: .id,
        role: $role_of[.id],
        type: .type,
        keyed: (.key != null),
        org: (.organizationId != null),
        archived: (.archivedDate != null),
        fido2: ((.login.fido2Credentials // []) | length),
        passwordHistory: ((.passwordHistory // []) | length),
        uris: ((.login.uris // []) | length),
        uriChecksums: ([(.login.uris // [])[] | select(.uriChecksum != null)] | length),
        attachments: ((.attachments // []) | length),
        sshFields: present_ssh_fields,
        revisionDate: .revisionDate}];
