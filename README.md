<p align="center">
  <img src="docs/images/logo.png" alt="Jollybar" width="112">
</p>

<h1 align="center">Jollybar</h1>

<p align="center">A jolly little menu bar buddy that keeps an eye on your Grok Bot usage.</p>

<p align="center">
  <a href="https://github.com/exbtpy/jollybar"><img src="https://img.shields.io/badge/macOS-14%2B-0E1416?style=flat-square" alt="macOS 14+"></a>
  <a href="https://github.com/exbtpy/jollybar"><img src="https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square" alt="Swift 5.9"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSD--2--Clause-2EC4B6?style=flat-square" alt="BSD 2-Clause"></a>
  <a href="https://github.com/exbtpy/jollybar/releases/latest"><img src="https://img.shields.io/github/v/release/exbtpy/jollybar?style=flat-square&color=138A7E" alt="Latest release"></a>
  <a href="https://github.com/exbtpy/jollybar"><img src="https://img.shields.io/badge/homebrew-exbtpy%2Ftap%2Fjollybar-F2C14E?style=flat-square&labelColor=0E1416" alt="Homebrew"></a>
</p>

<p align="center">
  <!-- Animated hero, once the file is added: docs/images/hero.gif -->
  <img src="docs/images/popover-playful-dark.png" width="260" alt="Bud, playful, with room left in the week">
  &nbsp;
  <img src="docs/images/popover-worried-dark.png" width="260" alt="Bud, worried, near the weekly limit">
</p>

## Install

```sh
brew install --cask exbtpy/tap/jollybar
```

Or download [Jollybar.dmg](https://github.com/exbtpy/jollybar/releases/latest/download/Jollybar.dmg).

The app is unsigned for now. The first time you open it, right-click Jollybar and choose **Open**.

## Meet Bud

Bud is the menu bar icon. The face follows the Grok Bot weekly meter. In Settings you can show it as a percent, usage bars, or a tiny Bud, and a few times a day Bud has a little moment: a morning stretch, a sweat drop, a yawn, or a reset-day bounce.

| | Mood | When |
| :---: | --- | --- |
| <img src="docs/images/bud-playful.png" width="72" alt="Playful"> | **Playful** | Under 50% used. |
| <img src="docs/images/bud-steady.png" width="72" alt="Steady"> | **Steady** | From 50% used. |
| <img src="docs/images/bud-tired.png" width="72" alt="Tired"> | **Tired** | From 75% used. |
| <img src="docs/images/bud-worried.png" width="72" alt="Worried"> | **Worried** | From 90% used. |
| <img src="docs/images/bud-asleep.png" width="72" alt="Asleep"> | **Asleep** | At 100%, or when the included limit is paused. |

## Features

- **Grok Bot week.** A menu bar meter and a countdown to the reset.
- **Pace.** A leaf marks how far the week has gone, and a forecast says if usage runs out early.
- **Cursor Models and on-demand spend.** Other Models sit with them. When the grok.com account has a SuperGrok pool, that pool is the other menu bar meter.
- **Sprout chart.** Seven days of the weekly rise, plus the longer history chart.
- **Notifications** when Grok Bot or the weekly pool crosses a percent you set.
- **English and Spanish.**
- **Privacy.** Reads your local Grok Bot session, makes no third-party calls, and never refreshes that token.

## How it works

Jollybar reads Grok Bot's local session and calls the same undocumented dashboard endpoints Cursor's usage view uses. It never reads or refreshes that token; open Grok Bot if the session expires. The project is unofficial.

Endpoints, environment variables, Sparkle, and the release steps live in [docs/TECHNICAL.md](docs/TECHNICAL.md). Cutting a release is [docs/RELEASING.md](docs/RELEASING.md).

## Build from source

macOS 14 and Xcode 15 or newer.

```sh
git clone https://github.com/exbtpy/jollybar.git
cd jollybar
make app
```

## Credits and license

Fork of [Blimp-Labs/claude-usage-bar](https://github.com/Blimp-Labs/claude-usage-bar) (BSD-2-Clause). The Grok Bot session reader is adapted from [nuno/grokbot-meter](https://github.com/nuno/grokbot-meter) (MIT). SuperGrok category names follow [blankspeaker/Grok-Rate-Limit-Display](https://github.com/blankspeaker/Grok-Rate-Limit-Display) (MIT). Bud's blink and hop timing borrow from [fayazara/robot-heads](https://github.com/fayazara/robot-heads) (MIT).

[BSD 2-Clause](LICENSE).

Not affiliated with xAI, SpaceXAI, or Cursor.
