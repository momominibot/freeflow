#!/bin/bash
# Builds FreeFlow.app.
#   ./build.sh            build only
#   ./build.sh install    also copy to /Applications and launch
#   ./build.sh release    also make dist/FreeFlow-<version>.zip with install.sh for teammates
set -euo pipefail
cd "$(dirname "$0")"

APP=build/FreeFlow.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Sources/*.swift \
  -o "$APP/Contents/MacOS/FreeFlow" \
  -framework AppKit -framework AVFoundation -framework ApplicationServices -framework ServiceManagement
cp Info.plist "$APP/Contents/"
cp scripts/freeflow-mcp.py "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/freeflow-mcp.py"
cp scripts/qwen_server.py scripts/install-qwen-engine.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/install-qwen-engine.sh"

swiftc -O scripts/make_icon.swift -o build/make_icon
build/make_icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# A real signing identity keeps macOS permissions across rebuilds; ad-hoc works but resets them.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
[ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier com.momominibot.freeflow "$APP"
codesign --verify "$APP" && echo "Built $APP $VERSION (signed with ${IDENTITY:-ad-hoc})"

"$APP/Contents/MacOS/FreeFlow" --test >/dev/null || { echo "Text pipeline checks failed; run $APP/Contents/MacOS/FreeFlow --test"; exit 1; }
echo "Text pipeline checks passed"

if [ "${1:-}" = "install" ]; then
  pkill -x FreeFlow || true
  sleep 0.5
  rm -rf /Applications/FreeFlow.app
  ditto "$APP" /Applications/FreeFlow.app
  open /Applications/FreeFlow.app
  echo "Installed and launched /Applications/FreeFlow.app"
fi

if [ "${1:-}" = "release" ]; then
  DIST="dist/FreeFlow-$VERSION"
  rm -rf "$DIST" "dist/FreeFlow-$VERSION.zip"
  mkdir -p "$DIST"
  ditto "$APP" "$DIST/FreeFlow.app"
  cp install.sh README.md "$DIST/"
  chmod +x "$DIST/install.sh"
  (cd dist && ditto -c -k --norsrc --keepParent "FreeFlow-$VERSION" "FreeFlow-$VERSION.zip")
  echo "Release: dist/FreeFlow-$VERSION.zip ($(du -h "dist/FreeFlow-$VERSION.zip" | cut -f1))"
  echo "Teammates: unzip, then run ./install.sh (or ./install.sh --with-ai)"
fi
