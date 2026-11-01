#!/bin/bash
# Builds FreeFlow.app. Pass "install" to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/FreeFlow.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Sources/*.swift \
  -o "$APP/Contents/MacOS/FreeFlow" \
  -framework AppKit -framework AVFoundation -framework ApplicationServices -framework ServiceManagement
cp Info.plist "$APP/Contents/"

swiftc -O scripts/make_icon.swift -o build/make_icon
build/make_icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# A real signing identity keeps macOS permissions across rebuilds; ad-hoc works but resets them.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier com.momominibot.freeflow "$APP"
codesign --verify "$APP" && echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [ "${1:-}" = "install" ]; then
  pkill -x FreeFlow || true
  sleep 0.5
  rm -rf /Applications/FreeFlow.app
  ditto "$APP" /Applications/FreeFlow.app
  open /Applications/FreeFlow.app
  echo "Installed and launched /Applications/FreeFlow.app"
fi
