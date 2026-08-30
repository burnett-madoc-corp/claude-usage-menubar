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

# One binary that runs on both CPU families. Building each slice with its own
# swiftc invocation (rather than `-target x86_64-apple-macosx13.0 arm64-…`,
# which swiftc does not accept) and stitching them together with lipo is the
# same approach Xcode itself uses under the hood for a multi-arch product.
# Set ARCHS=arm64 or ARCHS=x86_64 to compile a single slice (e.g. CodeQL CI).
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
    <!-- NOT local.claude-usage-menubar. ControlCenter's menu bar allow/deny
         list is keyed by bundle id, a denial written against an id is
         permanent, and nothing short of Reset Control Centre clears it. That
         id was poisoned on a real machine by a launchd job that exec'd the
         binary directly (see README). The id below is a clean one; the
         open(1) launch in install.sh is what stops it being poisoned too. -->
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

# Ad-hoc sign so the app has a signature at all; macOS is increasingly
# unwilling to run an unsigned bundle. It deliberately does no more than that:
# an ad-hoc signature's cdhash changes on every build, so it cannot be the
# thing that keeps the Keychain quiet — that is why this app's own items go
# through /usr/bin/security instead (see Sources/KeyStore.swift).
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc signing failed (app still runs)"

echo "Built $APP"
