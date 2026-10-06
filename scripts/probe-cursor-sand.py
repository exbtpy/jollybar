#!/usr/bin/env python3
"""Print the shape of the Cursor dashboard calls Grok Bot uses.

The access token is read from CURSOR_ACCESS_TOKEN, from --token-file, or by
decrypting Grok Bot's sand-secrets.json. It is never taken from the command
line, and it is never printed. The refresh token is not decrypted and is not
sent. Passwords read from the Keychain or --password-file are not printed.

    python3 scripts/probe-cursor-sand.py
    python3 scripts/probe-cursor-sand.py --token-file /path/to/access-token
    python3 scripts/probe-cursor-sand.py --secrets ~/Library/Application\\ Support/Grok\\ Bot/sand-secrets.json --password-file /path/to/safe-storage-secret
    python3 scripts/probe-cursor-sand.py --fixture sand.json period.json me.json

On macOS, with no --token-file and no --password-file, the script asks the
Keychain for the item "Grok Bot Safe Storage" / "Grok Bot Key" and derives
the same AES-128-CBC key Grok Bot uses. Exit 44 from security is "not signed
in". Any other security failure is reported as keychain access denied.

Exit codes: 0 ok, 2 no token, 3 HTTP or URL error, 4 unreadable body.
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_ROOT = "https://api2.cursor.sh"
METHODS = ("GetSandUsageStatus", "GetCurrentPeriodUsage", "GetMe")
PBKDF2_SALT = b"saltysalt"
PBKDF2_ITERS = 1003


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token-file", default=None, help="File whose contents are the access token")
    parser.add_argument("--secrets", default=None, help="Path to sand-secrets.json")
    parser.add_argument(
        "--password-file",
        default=None,
        help="File whose contents are the Grok Bot Safe Storage secret. Not printed.",
    )
    parser.add_argument("--url", default=API_ROOT, help="Dashboard origin. Only api2.cursor.sh or loopback.")
    parser.add_argument(
        "--fixture",
        nargs=3,
        metavar=("SAND", "PERIOD", "ME"),
        help="Redact three saved JSON files instead of calling the network",
    )
    args = parser.parse_args()

    if args.fixture:
        for label, path in zip(("sand", "period", "me"), args.fixture):
            payload = json.loads(Path(path).read_text(encoding="utf-8"))
            emit(label, payload)
        return 0

    if not allowed_url(args.url):
        print(
            "Refusing to send the access token anywhere but api2.cursor.sh or loopback.",
            file=sys.stderr,
        )
        return 3

    token = load_token(args.token_file, args.secrets, args.password_file)
    if token is None:
        return 2
    if not header_safe(token):
        print("The access token is not usable as an HTTP header.", file=sys.stderr)
        return 2

    root = args.url.rstrip("/")
    status = 0
    for method in METHODS:
        url = f"{root}/aiserver.v1.DashboardService/{method}"
        code, body = post(url, token)
        print(f"{method}: HTTP {code}", file=sys.stderr)
        if code != 200 or body is None:
            status = 3
            continue
        try:
            parsed = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            print(f"{method}: response was not JSON.", file=sys.stderr)
            status = 4
            continue
        emit(method, parsed)
    return status


def load_token(token_file, secrets, password_file):
    if token_file or os.environ.get("CURSOR_ACCESS_TOKEN"):
        token = read_file(token_file) if token_file else os.environ.get("CURSOR_ACCESS_TOKEN", "")
        token = (token or "").strip()
        if not token:
            print("The token file was empty.", file=sys.stderr)
            return None
        return token

    path = Path(secrets).expanduser() if secrets else first_existing_secrets()
    if path is None or not path.is_file():
        print(
            "No Grok Bot sand-secrets.json found. Set CURSOR_ACCESS_TOKEN, pass --token-file, or sign in with Grok Bot.",
            file=sys.stderr,
        )
        return None
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        print("Could not read sand-secrets.json.", file=sys.stderr)
        return None
    raw = access_field(document)
    if not raw:
        print("sand-secrets.json has no access token. Open Grok Bot to sign in.", file=sys.stderr)
        return None
    unwrapped = unwrap(raw, password_file)
    if unwrapped is None:
        return None
    if not looks_like_jwt(unwrapped):
        print("The decrypted value was not an access token.", file=sys.stderr)
        return None
    return unwrapped


def first_existing_secrets():
    home = Path.home()
    candidates = [
        home / "Library/Application Support/Grok Bot/sand-secrets.json",
        home / ".config/Grok Bot/sand-secrets.json",
        home / ".grokbot/sand-secrets.json",
        home / "Library/Application Support/Grok Bot/sand-client-persistence/sand-secrets.json",
        home / ".config/Grok Bot/sand-client-persistence/sand-secrets.json",
    ]
    for path in candidates:
        if path.is_file():
            return path
    return candidates[0]


def access_field(document):
    if not isinstance(document, dict):
        return None
    top = token_fields(document)
    account = active_account_fields(document)
    for fields in (top, account):
        if fields and fields.get("access"):
            return fields["access"]
    return None


def token_fields(obj):
    if not isinstance(obj, dict):
        return None
    access = obj.get("cursor-access-token") or obj.get("cursorAccessToken")
    refresh = obj.get("cursor-refresh-token") or obj.get("cursorRefreshToken")
    return {"access": access if isinstance(access, str) else None, "refresh": refresh if isinstance(refresh, str) else None}


def active_account_fields(document):
    raw = document.get("cursor-accounts", document.get("cursorAccounts", document.get("cursor_accounts")))
    if isinstance(raw, str):
        try:
            raw = json.loads(normalize(raw))
        except json.JSONDecodeError:
            return None
    if not isinstance(raw, dict):
        return None
    active = raw.get("active")
    accounts = raw.get("accounts")
    if not isinstance(active, str) or not isinstance(accounts, dict):
        return None
    account = accounts.get(active.strip())
    if not isinstance(account, dict):
        return None
    return token_fields(account)


def unwrap(raw, password_file):
    text = normalize(raw)
    if text.startswith("plaintext:v1:"):
        plain = text[len("plaintext:v1:") :].strip()
        return plain or None
    if text.startswith("scoped:v1:"):
        ciphertext = text.split(":")[-1]
        return decrypt_ciphertext(ciphertext, password_file)
    if looks_like_jwt(text):
        return text
    return decrypt_ciphertext(text, password_file)


def normalize(raw):
    text = raw.strip()
    if not text:
        return ""
    try:
        parsed = json.loads(text)
        if isinstance(parsed, str):
            return parsed.strip()
    except json.JSONDecodeError:
        pass
    return text


def decrypt_ciphertext(ciphertext, password_file):
    password = read_password(password_file)
    if password is None:
        return None
    try:
        data = base64.b64decode(ciphertext.strip(), validate=False)
    except (ValueError, TypeError):
        print("The access token ciphertext was not base64.", file=sys.stderr)
        return None
    if not data.startswith(b"v10") or len(data) <= 3 or (len(data) - 3) % 16 != 0:
        print("The access token ciphertext was not a v10 safeStorage blob.", file=sys.stderr)
        return None
    key = hashlib.pbkdf2_hmac("sha1", password.encode("utf-8"), PBKDF2_SALT, PBKDF2_ITERS, 16)
    iv = b" " * 16
    proc = subprocess.run(
        ["openssl", "enc", "-aes-128-cbc", "-d", "-K", key.hex(), "-iv", iv.hex(), "-nopad"],
        input=data[3:],
        capture_output=True,
    )
    if proc.returncode != 0 or not proc.stdout:
        print("Could not decrypt the Grok Bot access token.", file=sys.stderr)
        return None
    pad = proc.stdout[-1]
    if pad < 1 or pad > 16 or proc.stdout[-pad:] != bytes([pad]) * pad:
        print("Could not decrypt the Grok Bot access token.", file=sys.stderr)
        return None
    try:
        text = proc.stdout[:-pad].decode("utf-8").strip()
    except UnicodeDecodeError:
        print("Could not decrypt the Grok Bot access token.", file=sys.stderr)
        return None
    return text or None


def read_password(password_file):
    if password_file:
        secret = read_file(password_file).strip()
        if not secret:
            print("The password file was empty.", file=sys.stderr)
            return None
        return secret
    if sys.platform != "darwin":
        print(
            "Pass --password-file with the Grok Bot Safe Storage secret, or pass --token-file.",
            file=sys.stderr,
        )
        return None
    try:
        proc = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", "Grok Bot Safe Storage", "-a", "Grok Bot Key", "-w"],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        print("Keychain access denied. Reopen the terminal to retry.", file=sys.stderr)
        return None
    if proc.returncode == 44:
        print("Grok Bot Safe Storage was not in the Keychain.", file=sys.stderr)
        return None
    if proc.returncode != 0:
        print("Keychain access denied. Reopen the terminal to retry.", file=sys.stderr)
        return None
    secret = proc.stdout.strip()
    if not secret:
        print("Grok Bot Safe Storage was empty.", file=sys.stderr)
        return None
    return secret


def post(url, token):
    request = urllib.request.Request(url, data=b"{}", method="POST")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Content-Type", "application/json")
    request.add_header("Connect-Protocol-Version", "1")
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=20) as response:
            status = getattr(response, "status", None) or response.getcode()
            return status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, None
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", "request failed")
        print(f"Request failed: {reason}", file=sys.stderr)
        return 0, None


def emit(label, payload):
    print(f"# {label}")
    json.dump(redact(None, payload), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def redact(key, value):
    if isinstance(value, dict):
        return {str(child): redact(str(child), child_value) for child, child_value in value.items()}
    if isinstance(value, list):
        return [redact(key, child) for child in value]
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if key and "percent" in key.lower():
            return value
        return {"type": "number"}
    if isinstance(value, str):
        if looks_like_jwt(value) or "crsr_" in value.lower() or "bearer" in value.lower():
            return {"type": "string", "redacted": True}
        lowered = (key or "").lower()
        if lowered in {"email", "useremail", "user_email", "displayname", "display_name"}:
            return {"type": "string", "len": len(value)}
        if looks_like_timestamp(value):
            return value
        if len(value) <= 80 and " " not in value and "@" not in value:
            return value
        return {"type": "string", "len": len(value)}
    return {"type": type(value).__name__}


def looks_like_jwt(value):
    parts = value.split(".")
    if len(parts) != 3 or any(not part for part in parts):
        return False
    return len(value) >= 24


def looks_like_timestamp(value):
    return (
        len(value) >= 20
        and len(value) <= 40
        and value[0:4].isdigit()
        and value[4] == "-"
        and "T" in value
    )


def read_file(path):
    return Path(path).expanduser().read_text(encoding="utf-8")


def header_safe(value):
    return bool(value) and all(32 <= ord(ch) <= 126 for ch in value)


def allowed_url(url):
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme == "https" and host == "api2.cursor.sh":
        return True
    if parsed.scheme in {"http", "https"} and host in {"127.0.0.1", "localhost", "::1"}:
        return True
    return False


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


if __name__ == "__main__":
    sys.exit(main())
