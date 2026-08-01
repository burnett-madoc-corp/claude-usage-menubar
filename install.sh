#!/bin/bash
# Installs ClaudeUsage.app to /Applications and starts it at login.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh

DEST="/Applications/ClaudeUsage.app"
PLIST="$HOME/Library/LaunchAgents/local.claude-usage-menubar.plist"

echo "Installing to $DEST…"
pkill -f "ClaudeUsage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
rm -rf "$DEST"
cp -R build/ClaudeUsage.app "$DEST"

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>local.claude-usage-menubar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/ClaudeUsage</string>
    </array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$UID/local.claude-usage-menubar" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo "Installed and running. It will start automatically at login."
echo "Uninstall: launchctl bootout gui/$UID/local.claude-usage-menubar && rm -rf '$DEST' '$PLIST'"
