# Codex Status Bar

This folder contains:

- `CodexStatusBar.app`: macOS menu bar app.
- `codex-status`: legacy command line helper. The app no longer depends on it.

## Start

Open:

```sh
open /Users/bytedance/Documents/Codex/2026-07-05/mac-codex/outputs/CodexStatusBar.app
```

Or double-click `Start-CodexStatusBar.command`.

The app now reads real Codex hook state records at `~/.codex/statusbar/state.d`.
If the current Desktop session has not loaded hooks yet, it falls back to
Codex's own runtime log database at `~/.codex/logs_2.sqlite`.

It shows one of three states driven by real Codex hook events or Codex core log events:

- `Codex idle`
- `Codex running`
- `Codex done`

Install or repair hooks:

```sh
node /Users/bytedance/Documents/Codex/2026-07-05/mac-codex/outputs/CodexStatusBar.app/Contents/Resources/install-codex-statusbar.js --app-path /Users/bytedance/Documents/Codex/2026-07-05/mac-codex/outputs/CodexStatusBar.app
```

The default state directory is:

```text
~/.codex/statusbar/state.d
```

Use a custom state directory by launching the app with `CODEX_STATUSBAR_STATE_DIR`.
Use a custom log database by launching the app with `CODEX_LOG_DB`.
