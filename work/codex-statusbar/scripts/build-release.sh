#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_DIR/outputs"
APP_DIR="$OUTPUT_DIR/CodexStatusBar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$ROOT_DIR"
swift build -c release

mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources"
cp ".build/release/CodexStatusBar" "$MACOS_DIR/CodexStatusBar"
cp ".build/release/codex-status" "$OUTPUT_DIR/codex-status"
chmod +x "$MACOS_DIR/CodexStatusBar" "$OUTPUT_DIR/codex-status"

HOOKS_DIR="$ROOT_DIR/scripts/codex-hooks"
if [[ -d "$HOOKS_DIR" ]]; then
  cp "$HOOKS_DIR/codex-status-writer.js" "$CONTENTS_DIR/Resources/codex-status-writer.js"
  cp "$HOOKS_DIR/codex-lifecycle-writer.js" "$CONTENTS_DIR/Resources/codex-lifecycle-writer.js"
  cp "$HOOKS_DIR/install-codex-statusbar.js" "$CONTENTS_DIR/Resources/install-codex-statusbar.js"
  cp "$HOOKS_DIR/uninstall-codex-statusbar.js" "$CONTENTS_DIR/Resources/uninstall-codex-statusbar.js"
  rm -rf "$CONTENTS_DIR/Resources/lib"
  cp -R "$HOOKS_DIR/lib" "$CONTENTS_DIR/Resources/lib"
  chmod +x "$CONTENTS_DIR/Resources/codex-status-writer.js"
  chmod +x "$CONTENTS_DIR/Resources/codex-lifecycle-writer.js"
  chmod +x "$CONTENTS_DIR/Resources/install-codex-statusbar.js"
  chmod +x "$CONTENTS_DIR/Resources/uninstall-codex-statusbar.js"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CodexStatusBar</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex.statusbar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex Status Bar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Built $APP_DIR"
echo "Built $OUTPUT_DIR/codex-status"
