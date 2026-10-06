#!/usr/bin/env python3
"""
Mock Grok billing server for Grok Usage Bar.

Serves the undocumented SuperGrok credits payload and the documented
Management API balance/usage routes, plus a loopback OIDC refresh.

    python3 scripts/mock-server.py [--port 8080] [--scenario normal]

Point the app at it (loopback only):

    GROK_USAGE_BAR_AUTH_FILE=/tmp/grok-auth.json \\
    GROK_USAGE_BAR_PROXY_BASE=http://127.0.0.1:8080/v1 \\
    GROK_USAGE_BAR_MANAGEMENT_BASE=http://127.0.0.1:8080 \\
        macos/GrokUsageBar.app/Contents/MacOS/GrokUsageBar

The auth file must be a grok-cli-shaped JSON document. Any non-empty
``key`` is accepted. Scenario ``stale_then_ok`` returns 401 until the
bearer is ``refreshed-access``, which ``POST /oidc/token`` issues.

Scenarios:
    normal                  42% weekly, products, extra credits
    high                    92% weekly
    maxed                   100% weekly
    low                     2% weekly
    omitted_zero            weekly window, no creditUsagePercent (parser may show 0%)
    products_without_overall
                            product percents and no overall percent
    string_cents            prepaidBalance.val as a string
    monthly                 monthly period; not the weekly pool
    unauthenticated         401
    stale_then_ok           401 until the refreshed bearer arrives
    rate_limited            429
    error                   500 with a short error string
    echo_auth               500 whose error field repeats the bearer (redaction test)
    malformed               200 with a non-JSON body

Cursor routes (Basic auth, never logged):

    POST /teams/spend
    POST /teams/filtered-usage-events

The default Cursor payload is a member at person@example.com with a $50
spend limit and two events: 250 cents of grok_bot and 900 cents of cursor.
Grok Bot is therefore $2.50 of $50 (5%). These scenarios affect only the
Cursor routes; billing stays on the normal payload:

    cursor_unauthorized     401
    cursor_forbidden        403
    cursor_no_type          usage events omit application_type
    cursor_rate_limited     429 with Retry-After 60

Both Cursor responses send an ETag. A matching If-None-Match returns 304.
"""

import argparse
import json
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def iso_future(hours=0, days=0):
    dt = datetime.now(timezone.utc) + timedelta(hours=hours, days=days)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f+00:00")


def iso_past(days):
    dt = datetime.now(timezone.utc) - timedelta(days=days)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f+00:00")


def credits(percent, products, prepaid=1250, cap=0, used=0, unified=True, period="weekly"):
    start = iso_past(4)
    end = iso_future(days=3)
    period_type = (
        "USAGE_PERIOD_TYPE_WEEKLY" if period == "weekly" else "USAGE_PERIOD_TYPE_MONTHLY"
    )
    config = {
        "currentPeriod": {"type": period_type, "start": start, "end": end},
        "onDemandCap": {"val": cap},
        "onDemandUsed": {"val": used},
        "productUsage": products,
        "isUnifiedBillingUser": unified,
        "prepaidBalance": {"val": prepaid},
        "billingPeriodStart": start,
        "billingPeriodEnd": end,
    }
    if percent is not None:
        config["creditUsagePercent"] = percent
    return {"config": config}


SPECIAL_SCENARIOS = {
    "unauthenticated",
    "stale_then_ok",
    "rate_limited",
    "error",
    "echo_auth",
}

CURSOR_SCENARIOS = {
    "cursor_unauthorized",
    "cursor_forbidden",
    "cursor_no_type",
    "cursor_rate_limited",
}
SPEND_ETAG = '"spend-1"'
EVENTS_ETAG = '"events-1"'


def epoch_ms(dt):
    return int(dt.timestamp() * 1000)


def cursor_spend():
    start = datetime.now(timezone.utc) - timedelta(days=10)
    return {
        "teamMemberSpend": [
            {
                "userId": "user_example",
                "email": "person@example.com",
                "name": "Person Example",
                "role": "member",
                "spendCents": 250,
                "overallSpendCents": 250,
                "fastPremiumRequests": 1,
                "hardLimitOverrideDollars": 0,
                "monthlyLimitDollars": None,
                "effectivePerUserLimitDollars": 50,
            }
        ],
        "subscriptionCycleStart": epoch_ms(start),
        "totalMembers": 1,
        "totalPages": 1,
    }


def cursor_events(include_type=True):
    now_ms = epoch_ms(datetime.now(timezone.utc))

    def event(cents, application_type):
        row = {
            "timestamp": str(now_ms),
            "userEmail": "person@example.com",
            "model": "grok",
            "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
            "maxMode": False,
            "requestsCosts": 1,
            "isTokenBasedCall": True,
            "isChargeable": True,
            "isHeadless": False,
            "chargedCents": cents,
        }
        if include_type:
            row["application_type"] = application_type
        return row

    return {
        "totalUsageEventsCount": 2,
        "pagination": {"hasNextPage": False, "page": 1, "pageSize": 1000},
        "usageEvents": [event(250, "grok_bot"), event(900, "cursor")],
        "period": {"startDate": now_ms - 86400000, "endDate": now_ms},
    }


SCENARIOS = {
    "normal": lambda: credits(
        42.0,
        [
            {"product": "GrokBuild", "usagePercent": 30.0},
            {"product": "GrokChat", "usagePercent": 8.0},
            {"product": "GrokImagine", "usagePercent": 4.0},
        ],
    ),
    "high": lambda: credits(
        92.0,
        [{"product": "GrokBuild", "usagePercent": 92.0}],
        prepaid=0,
    ),
    "maxed": lambda: credits(
        100.0,
        [
            {"product": "GrokBuild", "usagePercent": 100.0},
            {"product": "GrokChat"},
        ],
        prepaid=0,
    ),
    "low": lambda: credits(2.0, [{"product": "GrokChat", "usagePercent": 2.0}]),
    "omitted_zero": lambda: credits(
        None,
        [{"product": "GrokChat"}],
        prepaid=0,
    ),
    "products_without_overall": lambda: credits(
        None,
        [{"product": "PRODUCT_GROK_BUILD", "usagePercent": 61.2}],
    ),
    "string_cents": lambda: {
        "config": {
            "currentPeriod": {
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": iso_past(1),
                "end": iso_future(days=6),
            },
            "creditUsagePercent": 15,
            "prepaidBalance": {"val": "2500"},
            "onDemandCap": {"val": "500"},
            "onDemandUsed": {"val": "0"},
            "productUsage": [],
        }
    },
    "monthly": lambda: credits(40.0, [], period="monthly"),
    "malformed": lambda: None,
}


class Handler(BaseHTTPRequestHandler):
    scenario = "normal"
    server_port = 0

    def log_message(self, fmt, *args):
        # Never log headers. The access line is method and path only.
        path = urlparse(self.path).path
        print(f"{self.command} {path}", flush=True)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        if path.startswith("/scenario/"):
            name = path.split("/", 2)[2]
            if name not in SCENARIOS and name not in SPECIAL_SCENARIOS and name not in CURSOR_SCENARIOS:
                self._json(404, {"error": "unknown scenario"})
                return
            Handler.scenario = name
            self._json(200, {"scenario": name})
            return

        if path == "/oidc/.well-known/openid-configuration":
            self._json(
                200,
                {
                    "issuer": f"http://127.0.0.1:{Handler.server_port}/oidc",
                    "token_endpoint": f"http://127.0.0.1:{Handler.server_port}/oidc/token",
                },
            )
            return

        if path == "/v1/billing" or path.endswith("/billing"):
            self._billing()
            return

        if path.startswith("/v1/billing/teams/") and path.endswith("/prepaid/balance"):
            if not self._require_management_key():
                return
            self._json(200, {"total": {"val": "-1000"}, "changes": []})
            return

        self._json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/oidc/token":
            length = int(self.headers.get("Content-Length", "0") or "0")
            _ = self.rfile.read(length) if length else b""
            self._json(
                200,
                {
                    "access_token": "refreshed-access",
                    "refresh_token": "refreshed-refresh",
                    "expires_in": 3600,
                    "token_type": "Bearer",
                },
            )
            return

        if path in {"/teams/spend", "/teams/filtered-usage-events"}:
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length:
                self.rfile.read(length)
            self._cursor(path)
            return

        if path.startswith("/v1/billing/teams/") and path.endswith("/usage"):
            if not self._require_management_key():
                return
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length:
                self.rfile.read(length)
            self._json(
                200,
                {
                    "timeSeries": [
                        {
                            "group": ["Chat grok"],
                            "dataPoints": [
                                {"timestamp": "2026-10-01T00:00:00Z", "values": [1.25]},
                                {"timestamp": "2026-10-02T00:00:00Z", "values": [0.25]},
                            ],
                        }
                    ],
                    "limitReached": False,
                },
            )
            return

        self._json(404, {"error": "not found"})

    def _billing(self):
        scenario = Handler.scenario
        auth = self.headers.get("Authorization", "")

        if scenario == "unauthenticated":
            self._json(401, {"error": "unauthorized"})
            return
        if scenario == "stale_then_ok" and auth != "Bearer refreshed-access":
            self._json(401, {"error": "unauthorized"})
            return
        if scenario == "rate_limited":
            body = json.dumps({"error": "rate limited"}).encode("utf-8")
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Retry-After", "1")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if scenario == "error":
            self._json(500, {"error": "billing unavailable"})
            return
        if scenario == "echo_auth":
            token = auth[7:].strip() if auth.startswith("Bearer ") else ""
            self._json(500, {"error": f"bad {token}"})
            return
        if scenario == "malformed":
            body = b"not-json"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if not auth.startswith("Bearer ") or len(auth) <= len("Bearer "):
            self._json(401, {"error": "unauthorized"})
            return

        payload = SCENARIOS.get(scenario, SCENARIOS["normal"])()
        self._json(200, payload)

    def _cursor(self, path):
        scenario = Handler.scenario if Handler.scenario in CURSOR_SCENARIOS else "ok"
        if scenario == "cursor_unauthorized":
            self._json(401, {"error": "invalid api key"})
            return
        if scenario == "cursor_forbidden":
            self._json(403, {"error": "enterprise required"})
            return
        if scenario == "cursor_rate_limited":
            body = json.dumps({"error": "rate limited"}).encode("utf-8")
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Retry-After", "60")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic ") or len(auth) <= len("Basic "):
            self._json(401, {"error": "unauthorized"})
            return

        etag = SPEND_ETAG if path == "/teams/spend" else EVENTS_ETAG
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path == "/teams/spend":
            payload = cursor_spend()
        else:
            payload = cursor_events(include_type=scenario != "cursor_no_type")
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _require_management_key(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or len(auth) <= len("Bearer "):
            self._json(401, {"error": "unauthorized"})
            return False
        return True

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description="Mock Grok usage endpoints")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--scenario", default="normal")
    parser.add_argument(
        "--port-file",
        default=None,
        help="Write the bound port to this path before serving (used by tests)",
    )
    args = parser.parse_args()
    known = set(SCENARIOS) | SPECIAL_SCENARIOS | CURSOR_SCENARIOS
    if args.scenario not in known:
        parser.error(f"unknown scenario {args.scenario}")
    Handler.scenario = args.scenario
    # The test binds a port, closes it, then asks us to listen there.
    ThreadingHTTPServer.allow_reuse_address = True
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    Handler.server_port = server.server_address[1]
    if args.port_file:
        port_path = Path(args.port_file)
        port_path.write_text(f"{Handler.server_port}\n", encoding="utf-8")
    # A single line, flushed, so a pipe reader can see the port without
    # waiting for a full block buffer.
    print(f"PORT {Handler.server_port}", flush=True)
    print(
        f"Mock Grok usage server running on http://127.0.0.1:{Handler.server_port}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
