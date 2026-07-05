#!/usr/bin/env bash
set -euo pipefail

APP="/Users/bytedance/Documents/Codex/2026-07-05/mac-codex/outputs/CodexStatusBar.app"

open "$APP"

echo "Codex Status Bar started."
echo "It reads ~/.codex/statusbar/state.d from Codex hooks and falls back to ~/.codex/logs_2.sqlite."
