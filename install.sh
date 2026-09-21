#!/bin/bash
# Build ContextMeter, install it to ~/Applications and start it at login.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.contextmeter.app"
DEST="$HOME/Applications/ContextMeter.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v swiftc >/dev/null || { echo "Needs the Xcode Command Line Tools: run  xcode-select --install  then try again."; exit 1; }

"$DIR/build.sh"

# Stop a running copy before replacing it.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "ContextMeter.app/Contents/MacOS/ContextMeter" 2>/dev/null || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "$DIR/ContextMeter.app" "$DEST"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/ContextMeter</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed. ContextMeter is in your menu bar and starts at login."
echo "For exact plan figures: click it, then Add Claude key…"
