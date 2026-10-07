#!/usr/bin/env python3
"""Print the shape of the live SuperGrok billing response.

Run this on your own Mac after ``grok login``. It reads the bearer token
from the grok CLI auth file, calls the credits endpoint, and prints keys
and types. Percentages, booleans, period/product names, and timestamps are
shown. Other strings and amounts are redacted. The token is never printed.

    python3 scripts/probe-grok-usage.py
    python3 scripts/probe-grok-usage.py --auth-file ~/.grok/auth.json
    python3 scripts/probe-grok-usage.py --fixture sample.json   # no network

Exit codes: 0 ok, 2 no usable session, 3 HTTP error, 4 unreadable body.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

OIDC_PREFIX = "https://auth.x.ai::"
LEGACY_SCOPE = "https://accounts.x.ai/sign-in"
API_KEY_SCOPE = "xai::api_key"
REJECT_MODES = {"api_key", "web_login", "grok"}
BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--auth-file", default=None)
    parser.add_argument("--fixture", default=None, help="Redact a saved JSON file instead of calling the network")
    parser.add_argument("--url", default=BILLING_URL)
    args = parser.parse_args()

    if args.fixture:
        payload = json.loads(Path(args.fixture).read_text())
        json.dump(redact(None, payload), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    if not allowed_probe_url(args.url):
        print(
            "Refusing to send the grok token anywhere but cli-chat-proxy.grok.com or loopback.",
            file=sys.stderr,
        )
        return 3

    auth_path = resolve_auth_path(args.auth_file)
    if not auth_path.is_file():
        print(f"No auth file at {auth_path}. Run `grok login` in Terminal.", file=sys.stderr)
        return 2

    try:
        document = json.loads(auth_path.read_text())
    except (OSError, json.JSONDecodeError):
        print("Could not read the grok auth file.", file=sys.stderr)
        return 2

    selected = select_credential(document)
    if selected is None:
        print("No usable grok login session in the auth file. Run `grok login`.", file=sys.stderr)
        return 2

    scope_key, entry = selected
    token = str(entry.get("key") or "").strip()
    user_id = str(entry.get("user_id") or "").strip()
    if not header_safe(token):
        print("The saved session token is not usable. Run `grok login`.", file=sys.stderr)
        return 2
    # Describe the selection without any secret material.
    print(f"scope: {scope_key}", file=sys.stderr)
    print(f"auth_mode: {entry.get('auth_mode')}", file=sys.stderr)
    print(f"expires_at_present: {bool(entry.get('expires_at'))}", file=sys.stderr)
    print(f"user_id_present: {bool(user_id)}", file=sys.stderr)

    request = urllib.request.Request(args.url)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("X-XAI-Token-Auth", "xai-grok-cli")
    request.add_header("Accept", "application/json")
    request.add_header("x-grok-client-version", "jollybar-probe")
    if header_safe(user_id):
        request.add_header("x-userid", user_id)

    # Do not follow redirects. A 3xx would otherwise carry the bearer token
    # to whatever host the response names.
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=20) as response:
            status = getattr(response, "status", None) or response.getcode()
            raw = response.read()
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code}", file=sys.stderr)
        # Do not print the body: it might echo input we sent.
        return 3
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", "request failed")
        print(f"Request failed: {reason}", file=sys.stderr)
        return 3

    print(f"HTTP {status}", file=sys.stderr)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        print("Response was not JSON.", file=sys.stderr)
        return 4

    json.dump(redact(None, payload), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def resolve_auth_path(explicit):
    if explicit:
        return Path(explicit).expanduser()
    override = os.environ.get("JOLLYBAR_AUTH_FILE") or os.environ.get("GROK_USAGE_BAR_AUTH_FILE")
    if override:
        return Path(override).expanduser()
    home = os.environ.get("GROK_HOME")
    if home:
        return Path(home).expanduser() / "auth.json"
    return Path.home() / ".grok" / "auth.json"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def header_safe(value):
    return bool(value) and all(32 <= ord(ch) <= 126 for ch in value)


def allowed_probe_url(url):
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme == "https" and host == "cli-chat-proxy.grok.com":
        return True
    if parsed.scheme in {"http", "https"} and host in {"127.0.0.1", "localhost", "::1"}:
        return True
    return False


def select_credential(document):
    if not isinstance(document, dict):
        return None
    entries = [(key, value) for key, value in document.items() if isinstance(value, dict)]

    def usable(item):
        key, entry = item
        token = entry.get("key")
        mode = str(entry.get("auth_mode") or "oidc").strip() or "oidc"
        return isinstance(token, str) and bool(token.strip()) and mode not in REJECT_MODES

    oidc = [item for item in entries if item[0].startswith(OIDC_PREFIX) and usable(item)]
    if oidc:
        return oidc[0]
    legacy = [item for item in entries if item[0] == LEGACY_SCOPE and usable(item)]
    if legacy:
        return legacy[0]
    others = [
        item
        for item in entries
        if item[0] != API_KEY_SCOPE and not item[0].startswith(OIDC_PREFIX) and item[0] != LEGACY_SCOPE and usable(item)
    ]
    return others[0] if others else None


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
        lowered = (key or "").lower()
        if lowered in {"type", "product"} and len(value) <= 80 and " " not in value:
            return value
        if looks_like_timestamp(value):
            return value
        return {"type": "string", "len": len(value)}
    return {"type": type(value).__name__}


def looks_like_timestamp(value):
    return (
        len(value) >= 20
        and len(value) <= 40
        and value[0:4].isdigit()
        and value[4] == "-"
        and "T" in value
    )


if __name__ == "__main__":
    sys.exit(main())
