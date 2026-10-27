#!/usr/bin/env python3
"""Token form for the Vaultwarden rig probes (stdlib only, run as `python3 -I`).

    token-form.py email    ENV_FILE                     trimmed, lowercased account email
    token-form.py form     ENV_FILE ITERS DEVICE_ID     url-encoded /identity/connect/token body
    token-form.py absent   ENV_FILE ITERS FILE...       exit 1 if a secret occurs in any FILE
    token-form.py selftest                              known-answer test, no network, no real account

Security goal: derive the login credentials of the throwaway rig account without the master
password, the master key or the server hash ever appearing in argv (visible to every process via
`ps`), in a log, or in a file the repo could pick up. Secrets enter through ENV_FILE
(dev-vault/.env, git-ignored, mode 600) and leave on stdout, which the caller pipes into curl's
stdin (`--data-binary @-`). The caller never echoes them.

Algorithm, mirroring what Prizm sends (PrizmCryptoService makeMasterKey / makeServerHash and
PrizmAPIClientImpl.identityToken), which is Bitwarden's PBKDF2 master-key derivation:
    masterKey  = PBKDF2-HMAC-SHA256(password, salt = trimmed lowercased email, iterations, 32 bytes)
    serverHash = base64(PBKDF2-HMAC-SHA256(masterKey, salt = password, 1 iteration, 32 bytes))
The iteration count comes from the server's prelogin answer; the caller has already failed closed
if the account's KDF is not PBKDF2-SHA256 (kdf 0).

Intentionally NOT done: no AES, no user-key unwrapping and no vault decryption. The probes work on
ciphertext the server returns; decryption belongs to the app under test. ENV_FILE is data, not
code: only the two keys below are read, other lines (the Lane A rig accounts) are ignored, and a
duplicated key is an error instead of "last one wins", because a silent pick could log in as the
wrong account.
"""

import base64
import contextlib
import hashlib
import io
import os
import subprocess
import sys
import tempfile
import urllib.parse

EMAIL_KEY = "PRIZM_RIG_EMAIL"
PASSWORD_KEY = "PRIZM_RIG_PASSWORD"

# Token form fields exactly as PrizmAPIClientImpl.identityToken sends them (no 2FA fields: the
# throwaway account has no two-step login).
FORM_FIELDS = (
    "grant_type", "username", "password", "scope", "client_id", "deviceType",
    "deviceIdentifier", "deviceName",
)

# The iteration count is server-supplied input. 5000 is the lowest PBKDF2 setting the official
# clients accept; the ceiling only stops a broken answer from hanging a probe.
MIN_ITERATIONS = 5000
MAX_ITERATIONS = 10_000_000

# Known-answer vector: a made-up account, not the rig's. Values from `openssl kdf` (see selftest).
KAT_PASSWORD = "kat-password"
KAT_EMAIL = "kat@example.com"
KAT_ITERATIONS = 1000
KAT_MASTER_KEY_B64 = "cilaFBKtxF+q9ywrxWBquEWHRuz6fZz8mUDHgfg2Urs="
KAT_SERVER_HASH_B64 = "PbXaPd+DiHzsnD+Du+oJYcsu+h0pXwlvgK73Kzwg5aQ="


def fail(message):
    sys.stderr.write("token-form: %s\n" % message)
    sys.exit(2)


def read_env(path):
    """Returns {EMAIL_KEY: ..., PASSWORD_KEY: ...}; values are used verbatim (no quote stripping)."""
    wanted = {EMAIL_KEY: None, PASSWORD_KEY: None}
    try:
        handle = open(path, encoding="utf-8")
    except OSError as error:
        fail("cannot read the env file: %s" % error.strerror)
    with handle:
        for line in handle:
            line = line.rstrip("\r\n")
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key not in wanted:
                continue
            if wanted[key] is not None:
                fail("%s appears more than once in the env file; rename the line of the other account" % key)
            wanted[key] = value
    for key, value in wanted.items():
        if not value:
            fail("%s is missing or empty in the env file" % key)
    return wanted


def normalise_email(raw):
    return raw.strip().lower()


def master_key(password, email, iterations):
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), email.encode("utf-8"), iterations, 32)


def server_hash(key, password):
    return base64.b64encode(hashlib.pbkdf2_hmac("sha256", key, password.encode("utf-8"), 1, 32)).decode("ascii")


def build_form(env, iterations, device_id):
    email = normalise_email(env[EMAIL_KEY])
    password = env[PASSWORD_KEY]
    key = master_key(password, email, iterations)
    params = [
        ("grant_type", "password"),
        ("username", email),
        ("password", server_hash(key, password)),
        ("scope", "api offline_access"),
        ("client_id", "desktop"),
        ("deviceType", "7"),
        ("deviceIdentifier", device_id),
        ("deviceName", "Prizm"),
    ]
    return urllib.parse.urlencode(params, quote_via=urllib.parse.quote, safe="-._~")


def secrets_for(env, iterations):
    """Every encoding of a secret that must not land in a file: password, master key, server hash."""
    email = normalise_email(env[EMAIL_KEY])
    password = env[PASSWORD_KEY]
    key = master_key(password, email, iterations)
    key_b64 = base64.b64encode(key).decode("ascii")
    hash_b64 = server_hash(key, password)
    return [
        password.encode("utf-8"),
        key_b64.encode("ascii"),
        hash_b64.encode("ascii"),
        urllib.parse.quote(hash_b64, safe="-._~").encode("ascii"),
    ]


def files_containing(secrets, paths):
    """Names (never contents) of the files in which any secret occurs."""
    hits = []
    for path in paths:
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError as error:
            fail("cannot read %s: %s" % (path, error.strerror))
        if any(secret in data for secret in secrets):
            hits.append(path)
    return hits


def parse_iterations(raw):
    try:
        value = int(raw)
    except ValueError:
        fail("iterations must be an integer")
    if not MIN_ITERATIONS <= value <= MAX_ITERATIONS:
        fail("iterations %d outside %d..%d" % (value, MIN_ITERATIONS, MAX_ITERATIONS))
    return value


def openssl_pbkdf2(password, salt, iterations, password_is_hex=False):
    """Independent derivation with OpenSSL, used only by selftest (test values only in argv)."""
    pass_option = "hexpass:" if password_is_hex else "pass:"
    result = subprocess.run(
        ["openssl", "kdf", "-keylen", "32", "-kdfopt", "digest:SHA256",
         "-kdfopt", pass_option + password, "-kdfopt", "salt:" + salt,
         "-kdfopt", "iter:%d" % iterations, "PBKDF2"],
        capture_output=True, text=True, check=False)
    if result.returncode != 0:
        fail("selftest needs `openssl kdf` (OpenSSL 3): %s" % result.stderr.strip())
    return bytes.fromhex(result.stdout.strip().replace(":", ""))


def refuses(action):
    """True when `action` ends in fail() (SystemExit) instead of returning."""
    try:
        action()
    except SystemExit:
        return True
    return False


def selftest():
    problems = []

    def check(condition, message):
        if not condition:
            problems.append(message)

    # 1. Known answer, against constants and against an independent OpenSSL derivation.
    key = master_key(KAT_PASSWORD, KAT_EMAIL, KAT_ITERATIONS)
    check(base64.b64encode(key).decode() == KAT_MASTER_KEY_B64, "master key differs from the known answer")
    check(server_hash(key, KAT_PASSWORD) == KAT_SERVER_HASH_B64, "server hash differs from the known answer")
    check(key == openssl_pbkdf2(KAT_PASSWORD, KAT_EMAIL, KAT_ITERATIONS), "master key differs from openssl kdf")
    check(hashlib.pbkdf2_hmac("sha256", key, KAT_PASSWORD.encode(), 1, 32)
          == openssl_pbkdf2(key.hex(), KAT_PASSWORD, 1, password_is_hex=True),
          "server hash differs from openssl kdf")

    with tempfile.TemporaryDirectory() as folder:
        env_path = os.path.join(folder, "env")
        with open(env_path, "w", encoding="utf-8") as handle:
            handle.write("# other account lines are ignored\n"
                         "OTHER_ACCOUNT_PASSWORD=not-this-one\n"
                         "%s= Kat@Example.com \n%s=%s\n" % (EMAIL_KEY, PASSWORD_KEY, KAT_PASSWORD))
        env = read_env(env_path)

        # 2. Email normalisation, form field set and values.
        check(normalise_email(env[EMAIL_KEY]) == KAT_EMAIL, "email is not trimmed and lowercased")
        form = urllib.parse.parse_qsl(build_form(env, KAT_ITERATIONS, "device-1"), keep_blank_values=True)
        fields = dict(form)
        check([name for name, _ in form] == list(FORM_FIELDS), "form field set or order changed")
        check(fields.get("grant_type") == "password", "grant_type")
        check(fields.get("username") == KAT_EMAIL, "username")
        check(fields.get("password") == KAT_SERVER_HASH_B64, "password field is not the server hash")
        check(fields.get("scope") == "api offline_access", "scope")
        check(fields.get("client_id") == "desktop", "client_id")
        check(fields.get("deviceType") == "7", "deviceType")
        check(fields.get("deviceIdentifier") == "device-1", "deviceIdentifier")
        check(fields.get("deviceName") == "Prizm", "deviceName")
        check(KAT_PASSWORD not in build_form(env, KAT_ITERATIONS, "device-1"), "form leaks the master password")

        # 3. The secret-absence check finds each encoding and names only the file.
        secrets = secrets_for(env, KAT_ITERATIONS)
        clean = os.path.join(folder, "clean")
        with open(clean, "w", encoding="utf-8") as handle:
            handle.write("token-free content\n")
        check(files_containing(secrets, [clean]) == [], "absent: false positive on a clean file")
        for label, value in (("password", KAT_PASSWORD), ("master key", KAT_MASTER_KEY_B64),
                             ("server hash", KAT_SERVER_HASH_B64),
                             ("encoded server hash", urllib.parse.quote(KAT_SERVER_HASH_B64, safe="-._~"))):
            dirty = os.path.join(folder, "dirty")
            with open(dirty, "w", encoding="utf-8") as handle:
                handle.write("prefix %s suffix\n" % value)
            check(files_containing(secrets, [dirty]) == [dirty], "absent: missed the %s" % label)

        # 4. A duplicated key is refused instead of picking one.
        duplicate = os.path.join(folder, "duplicate")
        with open(duplicate, "w", encoding="utf-8") as handle:
            handle.write("%s=a@example.com\n%s=x\n%s=b@example.com\n" % (EMAIL_KEY, PASSWORD_KEY, EMAIL_KEY))
        with contextlib.redirect_stderr(io.StringIO()):  # fail() reports on stderr; expected here
            refused = refuses(lambda: read_env(duplicate))
        check(refused, "duplicate key accepted")

    # 5. Iteration bounds fail closed.
    for bad in ("0", "4999", "10000001", "abc"):
        with contextlib.redirect_stderr(io.StringIO()):
            refused = refuses(lambda bad=bad: parse_iterations(bad))
        check(refused, "iterations %s accepted" % bad)
    check(parse_iterations("600000") == 600000, "600000 iterations rejected")

    if problems:
        for problem in problems:
            sys.stderr.write("token-form selftest FAILED: %s\n" % problem)
        return 1
    print("token-form selftest OK")
    return 0


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "selftest" and len(argv) == 2:
        return selftest()
    if mode == "email" and len(argv) == 3:
        sys.stdout.write(normalise_email(read_env(argv[2])[EMAIL_KEY]))
        return 0
    if mode == "form" and len(argv) == 5:
        sys.stdout.write(build_form(read_env(argv[2]), parse_iterations(argv[3]), argv[4]))
        return 0
    if mode == "absent" and len(argv) >= 5:
        secrets = secrets_for(read_env(argv[2]), parse_iterations(argv[3]))
        hits = files_containing(secrets, argv[4:])
        for path in hits:
            sys.stderr.write("secret found in %s\n" % path)
        return 1 if hits else 0
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
