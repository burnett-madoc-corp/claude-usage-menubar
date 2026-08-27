#!/bin/bash
# Installs ClaudeUsage.app to /Applications and starts it at login.
set -euo pipefail

cd "$(dirname "$0")"
./build.sh

DEST="/Applications/ClaudeUsage.app"
PLIST="$HOME/Library/LaunchAgents/local.claude-usage-menubar.plist"

echo "Installing to ${DEST}..."
# -x, not -f: an -f match is a substring of the full argv, so an editor or
# debugger with this app's binary path open on its command line (e.g.
# `lldb ClaudeUsage.app/Contents/MacOS/ClaudeUsage`) would match and get
# killed too. -x matches only the process name itself.
pkill -x ClaudeUsage 2>/dev/null || true
# ditto into place rather than `rm -rf` + `cp -R`. Deleting the bundle
# destroys the app identity macOS has records against; ditto replaces the
# contents while the bundle keeps existing at the same path.
mkdir -p "$DEST"
ditto build/ClaudeUsage.app "$DEST"

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>local.claude-usage-menubar</string>
    <!-- Launch through open(1), NOT the raw executable path.
         On macOS 26 a third-party status item is not a window the app draws:
         it is a scene hosted by ControlCenter, allowed or denied per app
         against a persisted list. A launchd job that execs a binary directly
         gets an "osservice" identity, whose default verdict is DENY, and that
         denial is then persisted against the bundle id — the menu bar item
         silently never appears, while System Settings still shows the app
         toggled on. Launching via open(1) gives the process a real
         application identity, whose default verdict is allow.
         -W makes open wait for the app to exit, so KeepAlive still works. -->
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
