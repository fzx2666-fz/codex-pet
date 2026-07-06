# Privacy

Codex Status Bar is designed to run locally on your Mac.

## Network

The app does not make network requests and does not send telemetry.

## Local Files Read

By default, the app reads:

- `~/.codex/statusbar/state.d/*.json`
- `~/.codex/logs_2.sqlite`

The hook installer reads and writes:

- `~/.codex/hooks.json`

It creates a one-time backup when possible:

- `~/.codex/hooks.json.bak-codex-status-bar`

## Local Data Written

The app stores the floating window position using macOS `UserDefaults`.

The Codex hook writers create status JSON files under:

- `~/.codex/statusbar/state.d`

## Log Fallback

When hook status files are missing or stale, the app queries Codex runtime logs
for coarse activity signals. It does not display prompt content. The current
implementation only uses timestamped runtime events to infer whether Codex is
idle, running, or recently done.

## Uninstalling Hooks

After building the app, uninstall hooks with:

```sh
node outputs/CodexStatusBar.app/Contents/Resources/uninstall-codex-statusbar.js
```
