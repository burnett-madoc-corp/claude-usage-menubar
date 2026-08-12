#!/bin/bash
# Builds ClaudeUsage.app — a menu bar app showing Claude 5-hour, weekly and
# per-model (Fable) rate-limit usage.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/ClaudeUsage.app"
BIN="$APP/Contents/MacOS/ClaudeUsage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/*-template.svg "$APP/Contents/Resources/"

echo "Compiling…"
swiftc -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework Security \
  -o "$BIN" \
  Sources/Providers.swift Sources/KeyStore.swift Sources/Prefs.swift \
  Sources/Sessions.swift Sources/CodexSessions.swift Sources/SettingsWindow.swift \
  Sources/Theme.swift Sources/PollPolicy.swift Sources/QuotaBlockView.swift \
  Sources/SessionRowView.swift Sources/main.swift

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

# Ad-hoc sign so the app has a signature at all; macOS is increasingly
# unwilling to run an unsigned bundle. It deliberately does no more than that:
# an ad-hoc signature's cdhash changes on every build, so it cannot be the
# thing that keeps the Keychain quiet — that is why this app's own items go
# through /usr/bin/security instead (see Sources/KeyStore.swift).
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc signing failed (app still runs)"

echo "Built $APP"
