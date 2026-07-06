# Contributing

Thanks for helping improve Codex Status Bar.

## Development

Build the macOS app:

```sh
cd work/codex-statusbar
./scripts/build-release.sh
```

Run the built app:

```sh
open outputs/CodexStatusBar.app
```

## Guidelines

- Keep the app local-only unless a change is explicitly documented and reviewed.
- Do not display prompt text, tool output, or sensitive log content in the UI.
- Preserve third-party license notices when adding assets or vendored code.
- Keep the floating UI compact and readable on small Mac menu bars.
- Prefer precise Codex runtime signals over time-based guesses.

## Pull Requests

Before opening a pull request:

```sh
cd work/codex-statusbar
./scripts/build-release.sh
```

Include screenshots or a short screen recording for UI changes.
