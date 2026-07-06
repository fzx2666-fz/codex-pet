#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$SCRIPT_DIR/CodexPet.app"

open "$APP"

echo "Codex Pet started."
echo "It reads ~/.codex/statusbar/state.d from Codex hooks and falls back to ~/.codex/logs_2.sqlite."
