# Codex Status Bar

A tiny macOS status app that shows the current Codex Desktop runtime state in a
draggable pixel-cat capsule.

It prefers hook state records written by Codex hook events:

```text
~/.codex/statusbar/state.d/<session_id>.json
```

If hook files are not available for the current Desktop session, it falls back
to Codex's own runtime log database:

```text
~/.codex/logs_2.sqlite
```

Set `CODEX_STATUSBAR_STATE_DIR` before launching the app if you want to use a different state directory.
Set `CODEX_LOG_DB` before launching the app if Codex stores logs elsewhere.

The display is driven by real Codex hook events or Codex core log events:

- `Codex running`: a session is thinking, using a tool, compacting, waiting, or requesting permission.
- `Codex done`: the latest selected session just completed.
- `Codex idle`: Codex is open and there are no active hook state records.
- `Codex closed`: Codex Desktop is not running.

## Build

```sh
./scripts/build-release.sh
```

Outputs:

- `outputs/CodexStatusBar.app`

## Use

1. Open `CodexStatusBar.app`.
2. Install hooks with the bundled installer:

```sh
node CodexStatusBar.app/Contents/Resources/install-codex-statusbar.js --app-path CodexStatusBar.app
```

3. Approve hooks in Codex if prompted, then start a new Codex prompt.

The app runs as an accessory app, so it stays in the menu bar and does not occupy the Dock.

## Third-party Code

The bundled hook writer scripts are vendored from
[PG408/codex-status-bar](https://github.com/PG408/codex-status-bar). Its MIT
license and notices are preserved under `third_party/PG408-codex-status-bar/`.

The bundled pixel cat sprite is `oneko.gif` from
[adryd325/oneko.js](https://github.com/adryd325/oneko.js). Its MIT license is
preserved under `third_party/oneko.js/`.
