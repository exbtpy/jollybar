#!/usr/bin/env python3
"""Print the shape of Cursor spend and usage-event responses.

The API key is read from the CURSOR_API_KEY environment variable or from
a file passed with --key-file. It is never taken from the command line,
and it is never printed. Emails, names, and ids are redacted. The string
``application_type`` is kept so you can see whether Grok Bot is labeled.

    CURSOR_API_KEY=crsr_... python3 scripts/probe-cursor-usage.py
    python3 scripts/probe-cursor-usage.py --key-file ~/.config/grok-usage-bar/cursor-key
    python3 scripts/probe-cursor-usage.py --fixture spend.json events.json

Exit codes: 0 ok, 2 no key, 3 HTTP or URL error, 4 unreadable body.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_ROOT = "https://api.cursor.com"
KEEP_STRING_KEYS = {"application_type", "kind", "role", "type"}
REDACT_KEYS = {
    "email",
    "name",
    "useremail",
    "userid",
    "serviceaccountid",
    "cloudagentid",
    "automationid",
    "user_id",
    "user_email",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-file", default=None, help="File whose contents are the API key")
    parser.add_argument("--url", default=API_ROOT, help="API root. Only api.cursor.com or loopback.")
    parser.add_argument(
        "--fixture",
        nargs=2,
        metavar=("SPEND", "EVENTS"),
        help="Redact two saved JSON files instead of calling the network",
    )
    args = parser.parse_args()

    if args.fixture:
        spend = json.loads(Path(args.fixture[0]).read_text())
        events = json.loads(Path(args.fixture[1]).read_text())
        emit("spend", spend, key="")
        emit("events", events, key="")
        return 0

    if not allowed_url(args.url):
        print(
            "Refusing to send the Cursor key anywhere but api.cursor.com or loopback.",
            file=sys.stderr,
        )
        return 3

    key = load_key(args.key_file)
    if not key:
        print(
            "Set CURSOR_API_KEY or pass --key-file. The key is not accepted as an argument.",
            file=sys.stderr,
        )
        return 2
    if not header_safe(key) or not key.startswith("crsr_"):
        print("The Cursor key is not usable. It should start with crsr_.", file=sys.stderr)
        return 2

    root = args.url.rstrip("/")
    now_ms = int(time.time() * 1000)
    start_ms = now_ms - 30 * 24 * 60 * 60 * 1000
    calls = [
        ("spend", f"{root}/teams/spend", {"page": 1, "pageSize": 100}),
        (
            "events",
            f"{root}/teams/filtered-usage-events",
            {"startDate": start_ms, "endDate": now_ms, "page": 1, "pageSize": 100},
        ),
    ]
    status = 0
    for label, url, payload in calls:
        code, body = post(url, payload, key)
        print(f"{label}: HTTP {code}", file=sys.stderr)
        if code != 200 or body is None:
            status = 3
            continue
        try:
            parsed = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            print(f"{label}: response was not JSON.", file=sys.stderr)
            status = 4
            continue
        emit(label, parsed, key)
    return status


def load_key(path):
    if path:
        try:
            return Path(path).expanduser().read_text(encoding="utf-8").strip()
        except OSError:
            return ""
    return os.environ.get("CURSOR_API_KEY", "").strip()


def post(url, payload, key):
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method="POST")
    token = base64_basic(key)
    request.add_header("Authorization", f"Basic {token}")
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json")
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=30) as response:
            status = getattr(response, "status", None) or response.getcode()
            return status, response.read()
    except urllib.error.HTTPError as exc:
        # Do not print the body: it might echo the key.
        return exc.code, None
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", "request failed")
        print(f"Request failed: {reason}", file=sys.stderr)
        return 0, None


def emit(label, payload, key):
    types = sorted(application_types(payload))
    if types:
        print(f"{label}: application_type values: {', '.join(types)}", file=sys.stderr)
    elif label == "events":
        print(f"{label}: application_type field absent", file=sys.stderr)
    print(f"# {label}")
    json.dump(redact(None, payload, key), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def application_types(value):
    found = set()
    if isinstance(value, dict):
        for child_key, child in value.items():
            if child_key == "application_type" and isinstance(child, str):
                found.add(child if child else '""')
            else:
                found.update(application_types(child))
    elif isinstance(value, list):
        for child in value:
            found.update(application_types(child))
    return found


def redact(key, value, secret):
    if isinstance(value, dict):
        return {str(child): redact(str(child), child_value, secret) for child, child_value in value.items()}
    if isinstance(value, list):
        return [redact(key, child, secret) for child in value]
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return {"type": "number"}
    if isinstance(value, str):
        if secret and secret in value:
            return {"type": "string", "redacted": True}
        if "crsr_" in value:
            return {"type": "string", "redacted": True}
        lowered = (key or "").lower()
        if lowered in REDACT_KEYS:
            return {"type": "string", "len": len(value)}
        if lowered in KEEP_STRING_KEYS and len(value) <= 80 and " " not in value:
            return value
        return {"type": "string", "len": len(value)}
    return {"type": type(value).__name__}


def base64_basic(key):
    import base64

    return base64.b64encode(f"{key}:".encode("utf-8")).decode("ascii")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def header_safe(value):
    return bool(value) and all(32 <= ord(ch) <= 126 for ch in value)


def allowed_url(url):
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme == "https" and host == "api.cursor.com":
        return True
    if parsed.scheme in {"http", "https"} and host in {"127.0.0.1", "localhost", "::1"}:
        return True
    return False


if __name__ == "__main__":
    sys.exit(main())
