#!/bin/bash
# Builds Purrscribe.app.
#   ./build.sh            build only
#   ./build.sh install    also copy to /Applications and launch
#   ./build.sh release    also make dist/Purrscribe-<version>.zip with install.sh for teammates
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Purrscribe.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The Harper grammar checker (Apache-2.0) is linked in when native/harper/libharper-macos.a exists. Without it Purrscribe still
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
  -o "$APP/Contents/MacOS/Purrscribe" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework ApplicationServices -framework ServiceManagement -framework CoreAudio -framework ScreenCaptureKit
cp Info.plist "$APP/Contents/"

# The monthly cloud plan's checkout link is left out of the repo on purpose. A build that should show "Subscribe" takes it from the
# environment: PURRSCRIBE_CHECKOUT_URL=https://buy.stripe.com/... ./build.sh release. Without it the plan says "Coming soon".
if [ -n "${PURRSCRIBE_CHECKOUT_URL:-}" ]; then
  case "$PURRSCRIBE_CHECKOUT_URL" in
    https://*) /usr/libexec/PlistBuddy -c "Add :PurrscribeCloudCheckoutURL string $PURRSCRIBE_CHECKOUT_URL" "$APP/Contents/Info.plist"
               echo "Cloud plan checkout link: set" ;;
    *) echo "PURRSCRIBE_CHECKOUT_URL must start with https:// (got something else), build stopped"; exit 1 ;;
  esac
fi
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
mkdir -p "$APP/Contents/Resources/Brand/art/sunset"
cp assets/art/sunset/*.webp "$APP/Contents/Resources/Brand/art/sunset/" 2>/dev/null || true   # the warm cat-only set (scripts/art/make_sunset_art.py)
cp assets/brand/logo-icon-sunset.png "$APP/Contents/Resources/Brand/" 2>/dev/null || true
cp assets/brand/wordmark-purrscribe-small.png assets/brand/wordmark-purrscribe.png "$APP/Contents/Resources/Brand/" 2>/dev/null || true   # the cursive wordmark (scripts/art/make_wordmark.py)
mkdir -p "$APP/Contents/Resources/Brand/art/cats"
cp assets/art/cats/*.webp "$APP/Contents/Resources/Brand/art/cats/" 2>/dev/null || true
# Brand pictures for the MCP page (scripts/art/make_app_logos.sh makes them).
mkdir -p "$APP/Contents/Resources/Brand/apps"
cp assets/brand/apps/*.png "$APP/Contents/Resources/Brand/apps/" 2>/dev/null || true
cp assets/brand/apps/NOTICE.txt "$APP/Contents/Resources/Brand/apps/"   # Nous Research's MIT notice stays with the Hermes picture

# A real signing identity keeps macOS permissions across rebuilds; ad-hoc works but resets them.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
[ -n "$IDENTITY" ] || IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier com.momominibot.freeflow "$APP"
codesign --verify "$APP" && echo "Built $APP $VERSION (signed with ${IDENTITY:-ad-hoc})"

"$APP/Contents/MacOS/Purrscribe" --test >/dev/null || { echo "Text pipeline checks failed; run $APP/Contents/MacOS/Purrscribe --test"; exit 1; }
echo "Text pipeline checks passed"

if [ "${1:-}" = "install" ]; then
  pkill -x Purrscribe || true
  pkill -x FreeFlow || true        # the app's old name, so an earlier install is quit as well
  sleep 0.5
  pkill -9 -x Purrscribe || true   # an app stuck inside macOS audio ignores the polite request
  pkill -9 -x FreeFlow || true
  sleep 0.3
  rm -rf /Applications/Purrscribe.app
  ditto "$APP" /Applications/Purrscribe.app
  # An earlier install lives at /Applications/FreeFlow.app and AI-app setups point at its freeflow-mcp.py. Leave a link under the old
  # path so they keep working; a fresh machine gets no link.
  if [ -d /Applications/FreeFlow.app ] && [ ! -L /Applications/FreeFlow.app ]; then
    rm -rf /Applications/FreeFlow.app
    ln -s Purrscribe.app /Applications/FreeFlow.app
  fi
  open /Applications/Purrscribe.app
  echo "Installed and launched /Applications/Purrscribe.app"
fi

if [ "${1:-}" = "release" ]; then
  DIST="dist/Purrscribe-$VERSION"
  rm -rf "$DIST" "dist/Purrscribe-$VERSION.zip"
  mkdir -p "$DIST"
  ditto "$APP" "$DIST/Purrscribe.app"
  cp install.sh README.md docs/LOCAL-MODEL-GUIDE.md "$DIST/"
  chmod +x "$DIST/install.sh"
  (cd dist && ditto -c -k --norsrc --keepParent "Purrscribe-$VERSION" "Purrscribe-$VERSION.zip")
  echo "Release: dist/Purrscribe-$VERSION.zip ($(du -h "dist/Purrscribe-$VERSION.zip" | cut -f1))"
  echo "Teammates: unzip, then run ./install.sh (or ./install.sh --with-ai). The free local model guide is in the zip: LOCAL-MODEL-GUIDE.md"
fi
