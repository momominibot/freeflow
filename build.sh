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

# The Harper grammar checker (Apache-2.0) is linked in when native/harper/libharper-macos.a exists. Without it FreeFlow still
# builds and uses a smaller built-in checker. scripts/build-harper.sh macos makes the library (needs Rust, a few minutes, once).
HARPER=()
if [ ! -f native/harper/libharper-macos.a ] && [ "${1:-}" = "release" ]; then
  scripts/build-harper.sh macos || echo "Harper did not build; the release will use the built-in checker."
fi
if [ -f native/harper/libharper-macos.a ]; then
  HARPER=(-DHARPER -import-objc-header rust/harper-ffi/harper.h native/harper/libharper-macos.a -Xlinker -lc++)
  echo "Grammar checker: Harper"
else
  echo "Grammar checker: built-in (run scripts/build-harper.sh macos for Harper)"
fi

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Sources/*.swift ${HARPER[@]+"${HARPER[@]}"} \
  -o "$APP/Contents/MacOS/FreeFlow" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework ApplicationServices -framework ServiceManagement -framework CoreAudio -framework ScreenCaptureKit
cp Info.plist "$APP/Contents/"
cp scripts/freeflow-mcp.py "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/freeflow-mcp.py"
cp scripts/qwen_server.py scripts/install-qwen-engine.sh "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Fonts"
cp assets/fonts/*.ttf assets/fonts/LICENSE.txt "$APP/Contents/Resources/Fonts/"
chmod +x "$APP/Contents/Resources/install-qwen-engine.sh"

# The logo and app icon are drawn by scripts/make_logo.py and kept in assets/brand.
cp assets/brand/AppIcon-cat.icns "$APP/Contents/Resources/AppIcon.icns"   # the cute-cat icon (scripts/art/make_cat_icon.py); AppIcon.icns is the pearly bubble
mkdir -p "$APP/Contents/Resources/Brand"
cp assets/brand/logo-mark.png assets/brand/logo-icon.png "$APP/Contents/Resources/Brand/"
mkdir -p "$APP/Contents/Resources/Brand/art"
cp assets/art/*.webp "$APP/Contents/Resources/Brand/art/" 2>/dev/null || true
mkdir -p "$APP/Contents/Resources/Brand/art/cats"
cp assets/art/cats/*.webp "$APP/Contents/Resources/Brand/art/cats/" 2>/dev/null || true
# Brand pictures for the MCP page (scripts/art/make_app_logos.sh makes them).
mkdir -p "$APP/Contents/Resources/Brand/apps"
cp assets/brand/apps/*.png "$APP/Contents/Resources/Brand/apps/" 2>/dev/null || true

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
  pkill -9 -x FreeFlow || true   # an app stuck inside macOS audio ignores the polite request
  sleep 0.3
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
