# Contributing to Claude Usage Bar

Thanks for your interest in contributing! This guide will help you get set up and make sure your changes land smoothly.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15+ / Swift 5.9+
- Python 3 (for the mock server, included with macOS)

## Getting started

```sh
git clone https://github.com/Blimp-Labs/claude-usage-bar.git
cd claude-usage-bar
make app
```

This builds the release binary via Swift Package Manager, bundles it as a `.app`, and codesigns it.

## Project structure

```
Sources/ClaudeUsageBar/
├── ClaudeUsageBarApp.swift      # App entry point, menu bar setup
├── UsageService.swift           # OAuth, polling, API calls
├── UsageModel.swift             # API response types
├── UsageHistoryModel.swift      # History data types, time ranges
├── UsageHistoryService.swift    # Persistence, downsampling
├── UsageChartView.swift         # Swift Charts trajectory view
├── PopoverView.swift            # Main popover UI
└── MenuBarIconRenderer.swift    # Menu bar icon drawing
```

## Build commands

| Command | What it does |
|---------|-------------|
| `make build` | Release build via `swift build` |
| `make app` | Build + create `.app` bundle |
| `make zip` | Build + bundle + zip for distribution |
| `make install` | Build + install to `/Applications` |
| `make clean` | Remove build artifacts |

## Testing with the mock server

A mock API server lets you test the app against different usage scenarios without needing a real Anthropic account:

```sh
python3 scripts/mock-server.py --scenario extra
```

To connect the app to the mock server:

1. In `UsageService.swift`, change the endpoint:
   ```swift
   private let usageEndpoint = URL(string: "http://127.0.0.1:8080/api/oauth/usage")!
   ```
2. Add local networking to `Resources/Info.plist`:
   ```xml
   <key>NSAppTransportSecurity</key>
   <dict>
       <key>NSAllowsLocalNetworking</key>
       <true/>
   </dict>
   ```
3. Rebuild and run the app, then click Refresh.

Available scenarios:

| Scenario | Description |
|----------|-------------|
| `normal` | Moderate usage (5h: 25%, 7d: 45%) |
| `high` | Near rate limit (5h: 85%, 7d: 92%) |
| `maxed` | Fully rate limited (100% / 100%) |
| `low` | Barely used (5h: 2%, 7d: 5%) |
| `extra` | Extra usage enabled ($52.30 / $280.00) |
| `extra_high` | Extra usage near limit ($94.50 / $100.00) |
| `per_model` | Per-model breakdown (Opus + Sonnet) |
| `all_features` | Everything: per-model + extra usage |
| `unauthenticated` | Returns 401 |
| `rate_limited` | Returns 429 with Retry-After |
| `error` | Returns 500 |

**Remember to revert the endpoint and Info.plist changes before committing.**

## Submitting changes

1. Fork the repo and create a branch from `main`
2. Keep PRs focused — one feature or fix per PR
3. Test your changes with the mock server when relevant
4. Make sure `make app` builds without errors
5. Open a pull request against `main`

### Code style

- Follow the existing conventions in the codebase
- SwiftUI views in separate files, one primary view per file
- Keep `UsageService` as the single source of truth for API state
- No third-party dependencies — the app is intentionally zero-dep

## License

By contributing, you agree that your contributions will be licensed under the [BSD 2-Clause License](LICENSE).
