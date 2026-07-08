# Codex Pet Swift Package

This directory contains the Swift package, hook writers, and release build
script for Codex Pet.

Most users should start from the repository root instead:

```sh
./scripts/install-and-start.sh
```

That command builds the app, installs Codex hooks, and starts `CodexPet.app`.

## Runtime State

It prefers per-session hook state records written by Codex hook events:

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

The floating pet shows a small collapsed cat by default. Hovering expands the
panel with the current Codex job count and recent hook-backed sessions. The
display is driven by real Codex hook events or Codex core log events:

- `Codex running`: a session is thinking, using a tool, compacting, waiting, or requesting permission.
- `Codex done`: a selected session just completed.
- `Codex idle`: Codex is open and there are no active hook state records.
- `Codex closed`: Codex Desktop is not running.

## Build

From the repository root:

```sh
./scripts/build-release.sh
```

Outputs:

- `dist/CodexPet.app`

## Use

From the repository root, use:

```sh
./scripts/install-and-start.sh
```

Or manually:

1. Build from the repository root with `./scripts/build-release.sh`.
2. Open `dist/CodexPet.app`.
3. Install hooks with the bundled installer:

```sh
node dist/CodexPet.app/Contents/Resources/install-codex-statusbar.js --app-path dist/CodexPet.app
```

4. Approve hooks in Codex if prompted, then start a new Codex prompt.

The app runs as an accessory app, so it stays in the menu bar and does not occupy the Dock.

## Third-party Code

The bundled hook writer scripts are vendored from
[PG408/codex-status-bar](https://github.com/PG408/codex-status-bar). Its MIT
license and notices are preserved under `third_party/PG408-codex-status-bar/`.

The bundled pixel cat sprite is `oneko.gif` from
[adryd325/oneko.js](https://github.com/adryd325/oneko.js). Its MIT license is
preserved under `third_party/oneko.js/`.
