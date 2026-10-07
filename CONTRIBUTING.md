# Contributing to Jollybar

Fork of [Blimp-Labs/claude-usage-bar](https://github.com/Blimp-Labs/claude-usage-bar) (BSD 2-Clause, Copyright (c) 2026, Krystian). Keep that notice in `LICENSE`.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15+ / Swift 5.9+
- Python 3 (mock server and the usage probe)

## Getting started

```sh
git clone https://github.com/exbtpy/jollybar.git
cd jollybar
make app
cd macos && swift test
```

## Layout

```
macos/Sources/Jollybar/
├── JollybarApp.swift
├── UsageService.swift          # polling, history, notifications
├── UsageProvider.swift         # weekly pool + Management API
├── CursorUsage.swift           # Grok Bot via the Cursor Admin API
├── GrokBillingParser.swift     # credits JSON, isolated on purpose
├── GrokAuthFile.swift          # ~/.grok/auth.json
├── PopoverView.swift
└── MenuBarIconRenderer.swift   # GB / Wk meters, drawn glyph
```

The weekly-pool request and the Cursor requests are documented in the README, including which fields are assumed. Change `GrokBillingParser.swift` or `CursorUsage.swift` when a live probe disagrees, and add a test next to the fixture.

## Mock server

```sh
python3 scripts/mock-server.py --port 8080
```

See the README for the loopback environment variables. Do not log or print tokens.

## Sparkle

Release builds use this repository's appcast. The steps to generate the EdDSA key and to cut a tag are in `docs/RELEASING.md`. Do not point `SUFeedURL` at the upstream appcast, and do not reuse the upstream `SUPublicEDKey`.

## Names

`macos/identity.env` and `macos/Sources/Jollybar/AppIdentity.swift` are the rename points. Keep them in sync. The companion pet is Bud.
