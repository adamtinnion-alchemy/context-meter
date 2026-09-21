#!/bin/bash
# Remove ContextMeter, its login item, its cache and its stored key.
LABEL="com.contextmeter.app"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "ContextMeter.app/Contents/MacOS/ContextMeter" 2>/dev/null || true
rm -rf "$HOME/Applications/ContextMeter.app" "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.claude/context-meter-usage.json"
security delete-generic-password -s com.contextmeter.sessionkey >/dev/null 2>&1 || true
defaults delete "$LABEL" >/dev/null 2>&1 || true
echo "ContextMeter removed."
