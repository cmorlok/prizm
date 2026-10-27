# Scrub for the golden /api/sync fixture (Phase 1 plan 05, D-12 as amended by D-20).
#
#   jq -f scripts/rig/scrub.jq --arg email prizm-fixture@example.com < raw-sync.json > golden.json
#
# Security goal: the scrubbed document may enter the tracked tree (Prizm/PrizmTests/Fixtures/), so
# it must carry no identity data and no live credential, yet it must stay a faithful Vaultwarden
# response that tests can decrypt.
#
# What is replaced
#   - every UUID found anywhere in the document (case-insensitive, document order, de-duplicated by
#     first appearance) becomes 00000000-0000-4000-8000-<12-digit index>. One map is applied to
#     every string, so the relations cipher-folder-collection-organization-user stay consistent
#     and ids inside attachment urls, policies or userDecryption are covered too;
#   - attachment ids (20 hex characters, not UUIDs) become a<19-digit index>, in the id and in the
#     url path;
#   - the attachment download token in every url (a signed JWT, valid for the live server) becomes
#     "?token=SCRUBBED" (research Pitfall 1);
#   - profile.name -> "Prizm Fixture", profile.securityStamp -> a fixed stamp, and the plaintext
#     organization names in profile.organizations and profile.organizationsNew (1.37.4 emits both)
#     -> "Prizm Fixture Org".
#
# What is deliberately kept, byte for byte
#   - every EncString (names, notes, login values, fido2 data, ssh key data, attachment keys,
#     collection and folder names), profile.key, profile.privateKey, accountKeys, the organization
#     keys and userDecryption: tests decrypt them with the committed test password (D-13), and any
#     change would make the fixture decrypt to garbage;
#   - every timestamp: the tests depend on the exact format the server emits (D-16);
#   - the email. It is the PBKDF2 salt of the master key (research Pitfall 8), so a placeholder
#     would make profile.key undecryptable. The account is registered with the fixed fixture email
#     (D-20) and the scrub refuses any other one instead of substituting it.
#
# Intentionally NOT done: no key sorting (the output keeps the server's key order), no EncString
# handling and no decryption: the scrub never needs a secret.

def uuid_re: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
def pad($n; $width): ("0000000000000000000" + ($n | tostring))[-$width:];
def dummy_uuid($n): "00000000-0000-4000-8000-" + pad($n; 12);
def dummy_attachment($n): "a" + pad($n; 19);

. as $in
| (if ($in.profile.email != $email) or ($in.userDecryption.masterPasswordUnlock.salt != $email)
   then error("account email is not the fixed fixture email (it is the PBKDF2 salt)")
   else . end)
# uuid (lowercase) -> dummy uuid, numbered by first appearance in document order.
| ([ .. | strings | match(uuid_re; "g").string | ascii_downcase ]
   | reduce .[] as $u ({}; if has($u) then . else .[$u] = dummy_uuid(length + 1) end)) as $uuids
| ([ $in.ciphers[]?.attachments[]?.id | select(. != null) ]
   | reduce .[] as $a ({}; if has($a) then . else .[$a] = dummy_attachment(length + 1) end)) as $atts
| walk(if type == "string"
       then gsub("(?<u>" + uuid_re + ")"; $uuids[.u | ascii_downcase])
       else . end)
| (.ciphers[]?.attachments[]?) |= (
    (.id // null) as $old
    | if $old == null then .
      else .id = $atts[$old]
        | .url |= (if type == "string"
                   then sub("/" + $old + "(?=[?]|$)"; "/" + $atts[$old])
                        | sub("[?]token=.*$"; "?token=SCRUBBED")
                   else . end)
      end)
| .profile.name = "Prizm Fixture"
| .profile.securityStamp = "00000000-0000-4000-8000-5ec000000000"
| (.organizations[]?, .profile.organizations[]?, .profile.organizationsNew[]?) |= (.name = "Prizm Fixture Org")
