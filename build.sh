#!/bin/bash
# Builds ClaudeUsage.app menu bar application.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/ClaudeUsage.app"
BIN="$APP/Contents/MacOS/ClaudeUsage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/*-template.svg "$APP/Contents/Resources/"

# Build universal slices separately with swiftc and combine with lipo.
ARCHS="${ARCHS:-universal}"

SRCS=(
  Sources/Providers.swift
  Sources/KeyStore.swift
  Sources/Prefs.swift
  Sources/Sessions.swift
  Sources/CodexSessions.swift
  Sources/OtherAgentSessions.swift
  Sources/SettingsWindow.swift
  Sources/Theme.swift
  Sources/PollPolicy.swift
  Sources/QuotaBlockView.swift
  Sources/SessionRowView.swift
  Sources/main.swift
)

if [ "$ARCHS" = "arm64" ]; then
  echo "Compiling (arm64)…"
  swiftc -O \
    -target arm64-apple-macosx13.0 \
    -framework AppKit \
    -framework Security \
    -o "$BIN" \
    "${SRCS[@]}"
elif [ "$ARCHS" = "x86_64" ]; then
  echo "Compiling (x86_64)…"
  swiftc -O \
    -target x86_64-apple-macosx13.0 \
    -framework AppKit \
    -framework Security \
    -o "$BIN" \
    "${SRCS[@]}"
else
  echo "Compiling (arm64)…"
  swiftc -O \
    -target arm64-apple-macosx13.0 \
    -framework AppKit \
    -framework Security \
    -o "$BIN-arm64" \
    "${SRCS[@]}"

  echo "Compiling (x86_64)…"
  swiftc -O \
    -target x86_64-apple-macosx13.0 \
    -framework AppKit \
    -framework Security \
    -o "$BIN-x86_64" \
    "${SRCS[@]}"

  echo "Combining into a universal binary…"
  lipo -create -output "$BIN" "$BIN-arm64" "$BIN-x86_64"
  rm -f "$BIN-arm64" "$BIN-x86_64"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeUsage</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <!-- ControlCenter menu bar allow/deny list keys permanent decisions by bundle id. -->
    <key>CFBundleIdentifier</key>      <string>local.claude-usage-menubar.app</string>
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

# Ad-hoc sign bundle to satisfy macOS execution requirements.
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc signing failed (app still runs)"

echo "Built $APP"
