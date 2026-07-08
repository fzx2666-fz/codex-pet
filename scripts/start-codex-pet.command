#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_DIR/dist/CodexPet.app"
INSTALLER="$APP/Contents/Resources/install-codex-statusbar.js"

if [[ ! -d "$APP" ]]; then
  echo "CodexPet.app was not found."
  echo "Run ./scripts/install-and-start.sh first."
  exit 1
fi

if command -v node >/dev/null 2>&1 && [[ -f "$INSTALLER" ]]; then
  node "$INSTALLER" --app-path "$APP"
else
  echo "Skipping hook repair. Node.js or the hook installer was not found."
fi

open "$APP"

echo "Codex Pet started."
echo "Hover the cat to expand active Codex jobs."
