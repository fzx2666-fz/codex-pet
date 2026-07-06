# Codex Status Bar

A tiny macOS status app for watching Codex Desktop activity at a glance.

It shows a draggable pixel-cat capsule with the current state:

- `idle`: Codex is open and no recent task is active.
- `running`: Codex is thinking, using tools, compacting, waiting, or asking for permission.
- `done`: the latest turn just completed.
- `closed`: Codex Desktop is not running.

The UI uses the classic MIT-licensed `oneko.gif` sprite from
[adryd325/oneko.js](https://github.com/adryd325/oneko.js).

## Requirements

- macOS 13 or newer
- Swift 5.9 or newer
- Codex Desktop
- Node.js, only for installing the optional Codex hook writers

## Build

```sh
cd work/codex-statusbar
./scripts/build-release.sh
```

Build outputs are written to:

```text
outputs/CodexStatusBar.app
outputs/codex-status
```

## Run

```sh
open outputs/CodexStatusBar.app
```

The floating capsule can be dragged. Its position is saved locally with
`UserDefaults`.

## Install Codex Hooks

The app works best when Codex hook events write status files into:

```text
~/.codex/statusbar/state.d
```

After building, install or repair hooks with:

```sh
node outputs/CodexStatusBar.app/Contents/Resources/install-codex-statusbar.js --app-path outputs/CodexStatusBar.app
```

The installer updates `~/.codex/hooks.json` and creates a backup at:

```text
~/.codex/hooks.json.bak-codex-status-bar
```

If hook files are unavailable, the app falls back to Codex runtime logs at:

```text
~/.codex/logs_2.sqlite
```

## Configuration

Set these environment variables before launching the app if your Codex files
live somewhere else:

```sh
CODEX_STATUSBAR_STATE_DIR=/path/to/state.d
CODEX_LOG_DB=/path/to/logs_2.sqlite
```

## Privacy

Codex Status Bar is local-only. It does not send telemetry or network requests.

The app reads local Codex state files and, as a fallback, local Codex runtime
logs. See `PRIVACY.md` for details.

## Repository Layout

```text
work/codex-statusbar/        Swift package and source code
work/codex-statusbar/scripts Codex hook installer and writer scripts
work/codex-statusbar/third_party
                              Third-party license notices
outputs/                     Local build output helpers
```

## License

MIT. See `LICENSE` and `NOTICE`.
