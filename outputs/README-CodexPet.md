# Codex Pet

This folder contains:

- `CodexPet.app`: macOS menu bar app.
- `codex-status`: legacy command line helper. The app no longer depends on it.

## Start

Open:

```sh
open outputs/CodexPet.app
```

Or double-click `Start-CodexPet.command`.

The app now reads real Codex hook state records at `~/.codex/statusbar/state.d`.
If the current Desktop session has not loaded hooks yet, it falls back to
Codex's own runtime log database at `~/.codex/logs_2.sqlite`.

It shows states driven by real Codex hook events or Codex core log events:

- `Codex idle`
- `Codex running`
- `Codex done`
- `Codex closed`

Install or repair hooks:

```sh
node outputs/CodexPet.app/Contents/Resources/install-codex-statusbar.js --app-path outputs/CodexPet.app
```

The default state directory is:

```text
~/.codex/statusbar/state.d
```

Use a custom state directory by launching the app with `CODEX_STATUSBAR_STATE_DIR`.
Use a custom log database by launching the app with `CODEX_LOG_DB`.
