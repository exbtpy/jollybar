# Contributing to Grok Usage Bar

Fork of [Blimp-Labs/claude-usage-bar](https://github.com/Blimp-Labs/claude-usage-bar) (BSD 2-Clause, Copyright (c) 2026, Krystian). Keep that notice in `LICENSE`.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15+ / Swift 5.9+
- Python 3 (mock server and the usage probe)

## Getting started

```sh
git clone https://github.com/exbtpy/grok-usage-bar.git
cd grok-usage-bar
make app
cd macos && swift test
```

## Layout

```
macos/Sources/GrokUsageBar/
├── GrokUsageBarApp.swift
├── UsageService.swift          # polling, history, notifications
├── UsageProvider.swift         # weekly pool + Management API
├── GrokBillingParser.swift     # credits JSON, isolated on purpose
├── GrokAuthFile.swift          # ~/.grok/auth.json
├── PopoverView.swift
└── MenuBarIconRenderer.swift   # drawn glyph, not a vendor logo
```

The weekly-pool request and its response fields are documented in the README. Change `GrokBillingParser.swift` when a live probe disagrees with an assumption, and add a test next to the fixture.

## Mock server

```sh
python3 scripts/mock-server.py --port 8080
```

See the README for the loopback environment variables. Do not log or print tokens.

## Sparkle

Updates are off unless this repository is given its own feed and keys. Do not point `SUFeedURL` at the upstream appcast.
