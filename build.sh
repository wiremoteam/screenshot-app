#!/bin/bash
set -euo pipefail

APP_NAME="ScreenshotApp"
APP_BUNDLE="${APP_NAME}.app"
RELEASE_BIN=".build/release/${APP_NAME}"

echo "==> Building ${APP_NAME} (release)..."
swift build -c release 2>&1

echo ""
echo "==> Creating .app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${RELEASE_BIN}"          "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist"    "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns"  "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing with entitlements..."
codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "ScreenshotApp.entitlements" \
    "${APP_BUNDLE}"

echo ""
echo "✅  Done! App bundle: ${APP_BUNDLE}"
echo ""
echo "To run:   open ${APP_BUNDLE}"
echo ""
echo "NOTE: On first launch macOS will ask for Screen Recording permission."
echo "      Grant it in System Settings → Privacy & Security → Screen Recording."
