#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_DIR/dist/CodexPet.app"
BUILD_SCRIPT="$REPO_DIR/scripts/build-release.sh"
INSTALLER="$APP_PATH/Contents/Resources/install-codex-statusbar.js"

print_step() {
  printf "\n==> %s\n" "$1"
}

require_command() {
  local name="$1"
  local hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    printf "Missing %s.\n%s\n" "$name" "$hint" >&2
    exit 1
  fi
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Codex Pet is a macOS app and can only be installed on macOS." >&2
  exit 1
fi

require_command swift "Install Xcode Command Line Tools, then try again: xcode-select --install"
require_command node "Install Node.js, then try again. Homebrew users can run: brew install node"

print_step "Building Codex Pet"
"$BUILD_SCRIPT"

print_step "Installing Codex hooks"
node "$INSTALLER" --app-path "$APP_PATH"

print_step "Starting Codex Pet"
open "$APP_PATH"

cat <<EOF

Codex Pet is ready.

What to do next:
1. Keep Codex Desktop open.
2. Start a new Codex prompt.
3. Hover the cat to expand the job list.

If Codex was already open before this install, start a new Codex prompt so the
new hooks can write fresh state.
EOF
