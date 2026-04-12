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

echo "1/5  Building..."
xcodebuild -scheme ClaudeUsage -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet

echo "2/5  Installing to /Applications..."
killall ClaudeUsage 2>/dev/null || true
killall ClaudeUsageWidgetExtension 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "3/5  Signing (ad-hoc, no developer account needed)..."
WIDGET="$APP_DST/Contents/PlugIns/ClaudeUsageWidgetExtension.appex"
codesign --force --deep --sign - \
  --entitlements "$PROJ_DIR/ClaudeUsageWidget/ClaudeUsageWidget.entitlements" \
  "$WIDGET"
codesign --force --sign - \
  --entitlements "$PROJ_DIR/ClaudeUsage.entitlements" \
  "$APP_DST"

echo "4/5  Registering widget..."
pluginkit -a "$WIDGET" 2>/dev/null || true
xattr -cr "$APP_DST"

echo "5/5  Launching..."
open "$APP_DST"

echo ""
echo "Done! ClaudeUsage is running in your menu bar."
echo ""
echo "To add the desktop widget:"
echo "  Right-click desktop → Edit Widgets → search 'Claude Usage'"
echo ""
echo "If the widget shows DEMO, run:"
echo "  killall ClaudeUsageWidgetExtension"
