#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/ContextMeter.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"

# Compile
swiftc -O -o "$MACOS/ContextMeter" "$DIR/src/main.swift" -framework Cocoa

# Info.plist
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ContextMeter</string>
  <key>CFBundleDisplayName</key><string>ContextMeter</string>
  <key>CFBundleIdentifier</key><string>com.contextmeter.app</string>
  <key>CFBundleExecutable</key><string>ContextMeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc codesign (personal use, unsigned identity)
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
