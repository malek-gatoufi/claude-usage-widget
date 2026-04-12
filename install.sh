#!/bin/bash
set -e

echo "=== ClaudeUsage installer ==="
echo ""

# Check Xcode tools
if ! xcodebuild -version &>/dev/null; then
  echo "ERROR: Xcode command line tools not found."
  echo "Install with: xcode-select --install"
  exit 1
fi

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR=/tmp/ClaudeUsageBuild
APP_SRC="$BUILD_DIR/Build/Products/Release/ClaudeUsage.app"
APP_DST=/Applications/ClaudeUsage.app
SERVER_SRC="$PROJ_DIR/widget-server.py"
SERVER_DST="$HOME/.claude-widget/widget-server.py"
LAUNCH_AGENT_DST="$HOME/Library/LaunchAgents/lekmax.ClaudeUsage.WidgetData.plist"

echo "1/6  Building..."
xcodebuild -scheme ClaudeUsage -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet

echo "2/6  Installing to /Applications..."
killall ClaudeUsage 2>/dev/null || true
killall ClaudeUsageWidgetExtension 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "3/6  Signing (ad-hoc, no developer account needed)..."
WIDGET="$APP_DST/Contents/PlugIns/ClaudeUsageWidgetExtension.appex"
codesign --force --deep --sign - \
  --entitlements "$PROJ_DIR/ClaudeUsageWidget/ClaudeUsageWidget.entitlements" \
  "$WIDGET"
codesign --force --sign - \
  --entitlements "$PROJ_DIR/ClaudeUsage.entitlements" \
  "$APP_DST"

echo "4/6  Registering widget..."
pluginkit -a "$WIDGET" 2>/dev/null || true
xattr -cr "$APP_DST"

echo "5/6  Installing widget data server (LaunchAgent)..."
mkdir -p "$HOME/.claude-widget"
cp "$SERVER_SRC" "$SERVER_DST"
chmod +x "$SERVER_DST"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LAUNCH_AGENT_DST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>lekmax.ClaudeUsage.WidgetData</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$SERVER_DST</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/ClaudeUsageWidget.log</string>
</dict>
</plist>
PLIST

# Reload LaunchAgent (stop old server if running, start new one)
launchctl unload "$LAUNCH_AGENT_DST" 2>/dev/null || true
launchctl load -w "$LAUNCH_AGENT_DST"

echo "6/6  Launching..."
open "$APP_DST"

echo ""
echo "Done! ClaudeUsage is running in your menu bar."
echo ""
echo "To add the desktop widget:"
echo "  Right-click desktop → Edit Widgets → search 'Claude Usage'"
echo ""
echo "Uninstall:"
echo "  launchctl unload ~/Library/LaunchAgents/lekmax.ClaudeUsage.WidgetData.plist"
echo "  rm ~/Library/LaunchAgents/lekmax.ClaudeUsage.WidgetData.plist"
echo "  rm -rf /Applications/ClaudeUsage.app"
