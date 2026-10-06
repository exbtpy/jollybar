# Grok Usage Bar

A macOS menu bar app that shows the shared weekly Grok usage pool.

This is a fork of [Blimp-Labs/claude-usage-bar](https://github.com/Blimp-Labs/claude-usage-bar) at commit `7232e065b8100f4280c3a26a9fcb6503b73bae15`. The original project is Copyright (c) 2026, Krystian, and remains under the BSD 2-Clause license in `LICENSE`. Upstream history is preserved on `main`.

The Grok Bot session reader is adapted from [grokbot-meter](https://github.com/nuno/grokbot-meter) (MIT, Copyright (c) 2026 Nuno Costa). SuperGrok category names follow [Grok-Rate-Limit-Display](https://github.com/blankspeaker/Grok-Rate-Limit-Display) (MIT, Copyright (c) 2026 blankspeaker). Both notices are in `LICENSE`.

The menu bar shows two short meters, in the same stacked layout as the original Claude Usage Bar. The top bar is **GB** (Grok Bot weekly usage from the Grok Bot app on this Mac). The bottom bar is **Wk** (SuperGrok) only when the signed-in grok.com account has a weekly pool. Otherwise the bottom bar is **CM** (Cursor Models). Other Models and on-demand spend sit in Details. Settings can switch the menu bar between Classic (chart glyph) and Companion (an original pet that follows Grok Bot weekly usage). The pet animation runs only while the popover is open. Each source fails on its own: a grok.com error does not clear Grok Bot, and the other way around.

## Build

Requires Xcode 15+ / Swift 5.9+ and macOS 14 (Sonoma) or later.

```sh
git clone https://github.com/exbtpy/grok-usage-bar.git
cd grok-usage-bar
make app        # build GrokUsageBar.app
make install    # copy it to /Applications
```

`make test` is not a target. From `macos/`:

```sh
swift test
```

## Sign in

The app does not run its own OAuth flow. It reads the session created by the official `grok` CLI.

```sh
grok login
```

That writes `~/.grok/auth.json` (or `$GROK_HOME/auth.json`). Open the menu bar item and choose Refresh. If the file is missing, or the only credential is an API key, the popover says to run `grok login`.

Tokens are not printed. When the access token is near expiry and the file has a refresh token, issuer, and client id, the app refreshes it with the issuer's OIDC token endpoint and writes the new token back to the same file. If refresh fails, the popover asks you to run `grok login` again. The auth file is never deleted by this app.

History is stored in `~/.config/grok-usage-bar/history.json` (mode `0600`). The grok.com pool and the Grok Bot session are polled every 5, 15, 30, or 60 minutes. The optional Teams Admin API is polled at most once an hour. Refresh can ask Cursor sooner, except after HTTP 429, which waits for `Retry-After`. Notification thresholds for Grok Bot and the weekly pool are separate and live in Settings.

## Optional Management API

Settings can store an xAI [management key](https://console.x.ai/team/default/management-keys) in the macOS Keychain and a team id in preferences. That reads:

- `GET https://management-api.x.ai/v1/billing/teams/{team_id}/prepaid/balance`
- `POST https://management-api.x.ai/v1/billing/teams/{team_id}/usage` (last 7 days, `usd` sum)

This is developer API credit and spend. It is not the SuperGrok weekly pool. The documented prepaid example uses a negative cent value for a purchase; the popover shows that signed dollar amount as returned.

## Grok Bot weekly usage

The primary Grok Bot source is the desktop app's Cursor session, read the same way as grokbot-meter. Parsing and the request live in `macos/Sources/GrokUsageBar/CursorDashboard.swift`.

The app looks for `sand-secrets.json` in:

- `~/Library/Application Support/Grok Bot/sand-secrets.json`
- `~/.config/Grok Bot/sand-secrets.json`
- `~/.grokbot/sand-secrets.json`
- the `sand-client-persistence` copies of the first two

It decrypts only `cursor-access-token` (or the active account's copy). Values may be `plaintext:v1:`, `scoped:v1:`, a raw JWT, or a Chromium `v10` blob. The Mac blob is AES-128-CBC with a key from PBKDF2-SHA1 (salt `saltysalt`, 1003 rounds) of the Keychain password `Grok Bot Safe Storage` / `Grok Bot Key`. The refresh token is never decrypted and never sent. This app does not refresh the sign-in. An expired token or HTTP 401 says "Open Grok Bot to refresh sign-in". A Keychain deny is remembered until relaunch.

Each call is `POST` with body `{}` and headers `Authorization: Bearer`, `Content-Type: application/json`, and `Connect-Protocol-Version: 1`.

| Item | What we use | Confidence |
| --- | --- | --- |
| `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` | `usagePercent` is the Grok Bot weekly used percent. `nextResetTimestampUtc` is the reset, or period start plus 7 days when that timestamp is missing. `includedLimitZero` pauses the companion. | High for the URL, method, headers, and these field names: they are what grokbot-meter sends. Not yet confirmed against this owner's token. |
| `POST …/GetCurrentPeriodUsage` | `planUsage.autoPercentUsed` is Cursor Models. `planUsage.apiPercentUsed` is Other Models. The same names are also accepted under `individualUsage.plan`. `spendLimitUsage.individualUsed` / `individualLimit` are on-demand cents. A limit at or above 2147483647 means no cap. A failed call is unknown, not "no cap". | Medium. The endpoint and on-demand fields match grokbot-meter. The Cursor Models / Other Models mapping comes from public Cursor usage parsers, not from a captured body on this account. If the field is absent, the row says so. |
| `POST …/GetMe` | `email`, or `user.email`, shown as a caption. A failure here does not fail the usage rows. | Medium. grokbot-meter reads the same names. |
| Teams fallback | Used only when no Grok Bot session file is present and a Cursor API key is saved. The top bar is then labeled **Sp** (spend), not the weekly meter. | High that the Admin API is Teams/Enterprise only. |

## Grok Bot spend (Teams fallback)

Settings can store a Cursor API key (`crsr_…`) in the Keychain (account `cursor-api-key`, service `com.exbtpy.GrokUsageBar`). This is optional. It is not used while a Grok Bot session file is present, including when that session is expired. The request is HTTP Basic with the key as the username and an empty password. An optional member email selects your row in team spend. An optional monthly budget is the percent denominator when that row has no per-user limit. An optional `org_…` id switches the calls to the organization routes and uses the contract end as the reset. The organization pool limit is not treated as a personal Grok Bot limit.

Parsing lives in `macos/Sources/GrokUsageBar/CursorUsage.swift`.

| Item | What we use | Confidence |
| --- | --- | --- |
| Base URL `https://api.cursor.com` and Basic auth | [Cursor API overview](https://cursor.com/docs/api), Admin API, Organization API. Key is `crsr_…`. | High. Documented. |
| `POST /teams/spend` | Member `email`, `effectivePerUserLimitDollars`, `subscriptionCycleStart` (epoch ms), `totalPages`. There is no documented GET for the spend limit. `POST /teams/user-spend-limit` is a write, and this app does not call it. | High for the fields that are in the Admin API reference (fetched 2026-10-06). |
| `POST /teams/filtered-usage-events` | `chargedCents` summed only when `application_type` is `grok_bot`. One page, up to 1000 events. `hasNextPage` marks the dollar line as partial. | Medium. `chargedCents` and the request body are documented. `application_type` is documented on audit logs (`grok_bot`, `cursor`, or empty), **not** on the published usage-event schema. If every event omits it, the bar stays empty and the row says so. Other Cursor spend is never counted as Grok Bot. |
| `POST /organizations/pooled-usage` and `POST /organizations/filtered-usage-events` | Used only when an organization id is set. `pool.contractEndDate` is the reset. `pool.limitCents` is not the personal denominator. | High for the documented fields. The same `application_type` caveat applies to organization events. |
| Billing-cycle end on the team path | `/teams/spend` has `subscriptionCycleStart` and no end. The reset shown is the next UTC calendar-month anniversary of that start. The row says when this estimate is used. | Low. The month length is an assumption. |
| Percent | `chargedCents / limit`. The limit is `effectivePerUserLimitDollars` when the email matches and the value is above 0, otherwise the monthly budget from Settings. | High given those inputs. Which one a real team populates is unverified. |
| `daily-usage-data` | Not used. Its counters are request counts and it has no `application_type`. | High that it cannot separate Grok Bot. |
| Polling, ETag, 401/403/429 | At most hourly. `If-None-Match` is sent and HTTP 304 keeps the last reading. 401 and 403 clear the Grok Bot reading and name the status. 429 keeps the last reading and waits for `Retry-After` (60 seconds when the header is missing, which is what the Admin API documents). | High for the status codes and Retry-After. ETag is documented for Analytics and AI Code Tracking, not for these Admin usage routes, so sending it is defensive. |
| Teams / Enterprise | These routes can reject a non-admin or non-enterprise key. The row shows that instead of failing silently. | High. Documented as plan and scope errors. |

No live Cursor account was called from this environment. `scripts/probe-cursor-usage.py` is how to check whether `application_type` is actually present on usage events.

## Where the weekly number comes from

There is no documented public API for the SuperGrok weekly pool. The primary provider repeats the call the Grok CLI makes in `xai-org/grok-build` `crates/codegen/xai-grok-shell/src/extensions/billing.rs`:

```text
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Authorization: Bearer <session key from ~/.grok/auth.json>
X-XAI-Token-Auth: xai-grok-cli
x-userid: <user_id, when present>
x-grok-client-version: grok-usage-bar
Accept: application/json
```

`x-grok-client-version` is this app's name, not the CLI's version. A captured call succeeded with only the bearer and `X-XAI-Token-Auth`. The CLI also sends `x-grok-client-mode`; this app does not, because that value is an internal process mode.

Parsing lives in `macos/Sources/GrokUsageBar/GrokBillingParser.swift`. Adjust it there if a live account disagrees with the table below.

| Item | What we use | Confidence |
| --- | --- | --- |
| URL and `format=credits` | CLI source `billing.rs`, plus claudia's live capture on 2026-08-10 | High. Verified from source. Not a public contract. |
| Auth file shape | CLI `auth/model.rs`. Scope map. OIDC key `https://auth.x.ai::<client id>`. Legacy key `https://accounts.x.ai/sign-in`. API keys live under `xai::api_key` and are ignored. Fields: `key`, `auth_mode`, `refresh_token`, `expires_at`, `create_time`, `user_id`, `email`, `oidc_issuer`, `oidc_client_id`. | High for the struct. The on-disk scope string is also in the CLI README and the enterprise install script. |
| `X-XAI-Token-Auth: xai-grok-cli` | CLI source and README | High |
| `creditUsagePercent` is **used** percent, 0–100 | CLI comment and claudia's check against the CLI panel | High |
| `currentPeriod.end`, else `billingPeriodEnd`, is the reset | CLI comment (`currentPeriod` preferred) and the claudia capture | High |
| `productUsage[].product` / `usagePercent` | Present in the claudia capture (`GrokBuild`, `GrokChat`) and in the CLI's own JSON fixture (`PRODUCT_GROK_BUILD`). The CLI struct currently ignores the field. | Medium. Names are not a stable enum. |
| `prepaidBalance.val` is Extra Usage Credits, USD cents | CLI comment calls it purchased credit. claudia maps it to the credits balance. `val` may be a number or a string; `{}` means 0. | Medium. The consumer UI label is not in the JSON. |
| A pool exists only when `creditUsagePercent` is present (including explicit 0) or a product row has `usagePercent` | The owner's Mac (2026-10-06) returned a weekly `currentPeriod`, cent fields, and `isUnifiedBillingUser`, with no percent and no `productUsage`. That account is treated as having no SuperGrok pool, so the bottom bar shows Cursor Models. Grok-Rate-Limit-Display treats period dates as a signal and would show 0% for that body. | High for that live shape. Explicit 0 remains 0% of a real pool. |
| Category names | `productUsage[].product` / `usagePercent`, same endpoint as Grok-Rate-Limit-Display. Known names include Grok Build, App Builder, Grok Chat, Chat, Imagine, Grok Plugins, Voice, API, and 3rd Party. | Medium. The names are not a stable enum. The owner's captured body had no `productUsage`. |
| A period whose `type` is not `USAGE_PERIOD_TYPE_WEEKLY` is not the weekly bar | CLI distinguishes weekly and monthly. OpenUsage documents unmigrated accounts as having no weekly pool. | Medium |
| `subscriptionTier` on this HTTP body | claudia: absent. The CLI fills it from remote settings after the request. Shown only when present. | High that it is usually missing |
| Token refresh | Standard OIDC refresh against `{issuer}/.well-known/openid-configuration` using the stored refresh token and client id. No PKCE login. | Medium. The CLI stores the fields and documents silent refresh. The exact form body was not captured from the binary. |
| Management API balance and usage | [xAI billing reference](https://docs.x.ai/developers/rest-api-reference/management/billing) | High for the routes and example JSON. The prepaid sign convention is taken from that example, not re-derived. |

If the unofficial endpoint fails, the popover shows the error, polling backs off (up to 60 minutes on HTTP 429 and server errors), and the process keeps running. Redirects are followed only when the next URL keeps the same scheme, host, and port, so the bearer token is not sent to another host. A token or user id that contains a character unsafe for an HTTP header is not sent.

## Probe a real account

On your Mac, after `grok login`:

```sh
python3 scripts/probe-grok-usage.py
```

The script prints the JSON shape. Percentages, booleans, product and period names, and timestamps are kept. Other strings and amounts are redacted. The bearer token is not printed, and redirects are not followed. `--url` is accepted only for `https://cli-chat-proxy.grok.com` or a loopback host. Use the output to adjust `GrokBillingParser.swift` if a field differs.

`--fixture file.json` redacts a saved body with no network, for checking the redactor.

## Probe the Cursor dashboard Grok Bot uses

On your Mac, with Grok Bot signed in:

```sh
python3 scripts/probe-cursor-sand.py
```

The script POSTs the three dashboard methods, prints HTTP status on stderr, and prints JSON shape on stdout. Percent numbers, booleans, short tokens, and timestamps are kept. Emails are reduced to a length. Any string that looks like a JWT, or that contains `crsr_` or `bearer`, is redacted. The access token and the Keychain password are not printed. The refresh token is not read. Redirects are not followed. `--url` is accepted only for `https://api2.cursor.sh` or a loopback host.

```sh
python3 scripts/probe-cursor-sand.py --token-file /path/to/access-token
python3 scripts/probe-cursor-sand.py --fixture sand.json period.json me.json
```

`--fixture` redacts saved bodies with no network.

## Probe Cursor Admin API

On your Mac, with a Cursor API key that is allowed to call the Admin API:

```sh
CURSOR_API_KEY='crsr_…' python3 scripts/probe-cursor-usage.py
```

The key can also be passed as `--key-file /path/to/file`. It is not accepted as a command-line argument, and it is not printed. The script POSTs `/teams/spend` and one page of `/teams/filtered-usage-events`, prints HTTP status on stderr, and prints the JSON shape on stdout. Emails, names, ids, and any string containing `crsr_` are redacted. `application_type` values are kept, and stderr says whether that field was absent. Redirects are not followed. `--url` is accepted only for `https://api.cursor.com` or a loopback host.

```sh
python3 scripts/probe-cursor-usage.py --fixture spend.json events.json
```

redacts two saved bodies with no network.

## Mock server

```sh
python3 scripts/mock-server.py --port 8080 --scenario normal
```

Scenarios include `normal`, `high`, `maxed`, `low`, `omitted_zero` (no SuperGrok pool), `products_without_overall`, `string_cents`, `monthly`, `unauthenticated`, `stale_then_ok`, `rate_limited`, `error`, and `echo_auth`. Cursor Admin scenarios are `cursor_unauthorized`, `cursor_forbidden`, `cursor_no_type`, and `cursor_rate_limited`. `sand_unauthorized` returns 401 on the dashboard routes only. `GET /scenario/<name>` switches one without a restart.

The mock also serves `POST /teams/spend` and `POST /teams/filtered-usage-events` with Basic auth. The sample member is `person@example.com` with a $50 spend limit, 250 cents of `grok_bot`, and 900 cents of other Cursor usage, so Grok Bot spend is 5%. Responses include an ETag; a matching `If-None-Match` returns 304.

It also serves the three `POST /aiserver.v1.DashboardService/…` routes with Bearer auth. The sample is Grok Bot weekly 8%, Cursor Models 7%, Other Models 0%, and on-demand 150 of 2000 cents. The Authorization header is not logged.

Only loopback overrides are honored, so tokens and API keys cannot be redirected off the machine:

```sh
GROK_USAGE_BAR_AUTH_FILE=/tmp/grok-auth.json \
GROK_USAGE_BAR_PROXY_BASE=http://127.0.0.1:8080/v1 \
GROK_USAGE_BAR_MANAGEMENT_BASE=http://127.0.0.1:8080 \
GROK_USAGE_BAR_CURSOR_BASE=http://127.0.0.1:8080 \
GROK_USAGE_BAR_CURSOR_DASHBOARD_BASE=http://127.0.0.1:8080 \
GROK_USAGE_BAR_SAND_SECRETS=/tmp/sand-secrets.json \
  macos/GrokUsageBar.app/Contents/MacOS/GrokUsageBar
```

`/tmp/grok-auth.json` needs a grok-cli-shaped session entry. Any non-empty `key` is accepted by the mock. The Cursor key is entered in Settings (the mock accepts any Basic key that starts with `crsr_` and is at least 16 characters).

## Updates

Sparkle is compiled in and left unconfigured: the app bundle has no feed URL and no upstream public key, so it will not check Blimp-Labs' appcast. The release workflow refuses a repository or feed URL that points at that project, and it skips appcast publishing unless `SPARKLE_PRIVATE_KEY` is set on this repository.
