# Grok Usage Bar

A macOS menu bar app that shows the shared weekly Grok usage pool.

This is a fork of [Blimp-Labs/claude-usage-bar](https://github.com/Blimp-Labs/claude-usage-bar) at commit `7232e065b8100f4280c3a26a9fcb6503b73bae15`. The original project is Copyright (c) 2026, Krystian, and remains under the BSD 2-Clause license in `LICENSE`. Upstream history is preserved on `main`.

The menu bar shows one bar for the weekly pool. The popover adds the per-product breakdown, the reset countdown, Extra Usage Credits, a history chart, and an optional view of xAI Management API prepaid balance and recent API spend.

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

History is stored in `~/.config/grok-usage-bar/history.json` (mode `0600`). Polling intervals are 5, 15, 30, and 60 minutes. The weekly-pool notification threshold is in Settings.

## Optional Management API

Settings can store an xAI [management key](https://console.x.ai/team/default/management-keys) in the macOS Keychain and a team id in preferences. That reads:

- `GET https://management-api.x.ai/v1/billing/teams/{team_id}/prepaid/balance`
- `POST https://management-api.x.ai/v1/billing/teams/{team_id}/usage` (last 7 days, `usd` sum)

This is developer API credit and spend. It is not the SuperGrok weekly pool. The documented prepaid example uses a negative cent value for a purchase; the popover shows that signed dollar amount as returned.

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
| Omitted `creditUsagePercent` plus a weekly window and no positive product percent means 0% | proto3 omits zero scalars (CLI comment on `Cent`). Not confirmed on a live zero-usage account. | Low. The popover says when this assumption was used. If products report usage and the overall percent is missing, the bar stays empty. |
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

## Mock server

```sh
python3 scripts/mock-server.py --port 8080 --scenario normal
```

Scenarios include `normal`, `high`, `maxed`, `low`, `omitted_zero`, `products_without_overall`, `string_cents`, `monthly`, `unauthenticated`, `stale_then_ok`, `rate_limited`, `error`, and `echo_auth`. `GET /scenario/<name>` switches one without a restart.

Only loopback overrides are honored, so the bearer token cannot be redirected off the machine:

```sh
GROK_USAGE_BAR_AUTH_FILE=/tmp/grok-auth.json \
GROK_USAGE_BAR_PROXY_BASE=http://127.0.0.1:8080/v1 \
GROK_USAGE_BAR_MANAGEMENT_BASE=http://127.0.0.1:8080 \
  macos/GrokUsageBar.app/Contents/MacOS/GrokUsageBar
```

`/tmp/grok-auth.json` needs a grok-cli-shaped session entry. Any non-empty `key` is accepted by the mock.

## Updates

Sparkle is compiled in and left unconfigured: the app bundle has no feed URL and no upstream public key, so it will not check Blimp-Labs' appcast. The release workflow refuses a repository or feed URL that points at that project, and it skips appcast publishing unless `SPARKLE_PRIVATE_KEY` is set on this repository.
