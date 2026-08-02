#!/bin/bash
# Builds ClaudeUsage.app — a menu bar app showing Claude 5-hour, weekly and
# per-model (Fable) rate-limit usage.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/ClaudeUsage.app"
BIN="$APP/Contents/MacOS/ClaudeUsage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -o "$BIN" \
  Sources/Providers.swift Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeUsage</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleIdentifier</key>      <string>local.claude-usage-menubar</string>
    <key>CFBundleExecutable</key>      <string>ClaudeUsage</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the Keychain grants a stable identity to the "always allow"
# decision — without this, every rebuild re-prompts for Keychain access.
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc signing failed (app still runs)"

echo "Built $APP"
