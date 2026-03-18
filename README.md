# CodexSwitcher

A lightweight macOS menu bar app for switching between multiple [Codex](https://openai.com/codex) accounts and monitoring rate limits.

## Features

- **Multi-account management** — Switch between saved Codex accounts with one click
- **Real-time rate limits** — View 5-hour and weekly usage for all accounts via progress bars
- **Smart alerts** — Status bar icon changes when quota is low (configurable thresholds)
- **System notifications** — Get notified when usage drops below alert thresholds
- **Auto-sync** — Automatically detects new accounts after `codex login`
- **Configurable refresh** — Auto-refresh interval and alert thresholds adjustable from the menu
- **Launch at Login** — Optional auto-start on macOS login
- **Single file, zero dependencies** — One Swift file, no packages, ~700 lines

## Screenshots

| Normal | 5h Alert | Week Alert |
|--------|----------|------------|
| Standing AI | Tired AI | Lying AI |

## Requirements

- macOS 12.0+
- [Codex](https://openai.com/codex) app installed (`/Applications/Codex.app`)
- At least one account logged in (`codex login`)

## Install

### Download

Download `CodexSwitcher.zip` from the [Releases](../../releases) page, unzip, and drag to Applications.

> First launch: Right-click → Open (to bypass Gatekeeper for unsigned builds).

### Build from source

```bash
git clone https://github.com/jieguangzhou/CodexSwitcher.git
cd CodexSwitcher
bash build.sh
open CodexSwitcher.app
```

## How it works

- Reads account credentials from `~/.codex/accounts/*.json`
- Queries `https://chatgpt.com/backend-api/wham/usage` directly for each account's rate limits
- Switches accounts by swapping `~/.codex/auth.json`
- Stores settings in `~/.codex/switcher.json`

## Configuration

All settings are configurable from the menu bar:

| Setting | Default | Options |
|---------|---------|---------|
| Auto Refresh | 30 min | 5m / 15m / 30m / 1h / 2h / Off |
| 5h Alert Below | 30% | 10% / 20% / 30% / 50% |
| Week Alert Below | 10% | 5% / 10% / 20% / 30% |

## License

MIT
