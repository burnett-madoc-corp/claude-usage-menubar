#!/bin/bash
# Installs ClaudeUsage.app to /Applications and starts it at login.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh

DEST="/Applications/ClaudeUsage.app"
PLIST="$HOME/Library/LaunchAgents/local.claude-usage-menubar.plist"

echo "Installing to ${DEST}..."
# Match exact process name to avoid killing editor/debugger processes containing the path.
# Stop KeepAlive before terminating app to prevent launchd from relaunching old binary during copy.
launchctl bootout "gui/$UID/local.claude-usage-menubar" 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true
sleep 1
# Preserve bundle directory identity across upgrades using ditto.
mkdir -p "$DEST"
ditto build/ClaudeUsage.app "$DEST"

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>local.claude-usage-menubar</string>
    <!-- Launch via open(1) with -W so ControlCenter grants normal application menu bar status. -->
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-W</string>
        <string>-a</string>
        <string>$DEST</string>
    </array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$UID/local.claude-usage-menubar" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo "Installed and running. It will start automatically at login."
echo
echo "If the menu bar item does not appear, macOS has this app on its blocked"
echo "list (System Settings > Menu Bar > Allow in the Menu Bar). Toggle"
echo "ClaudeUsage off and back on there, then run:"
echo "  pkill -x ClaudeUsage    # KeepAlive relaunches it via open(1)"
echo
echo "Note: launchctl kickstart no longer restarts the app. The launchd job is"
echo "open(1), which exits immediately; killing it leaves the app running, so"
echo "the status item is never re-registered. Kill the app itself."
echo "Uninstall: launchctl bootout gui/$UID/local.claude-usage-menubar && rm -rf '$DEST' '$PLIST'"
