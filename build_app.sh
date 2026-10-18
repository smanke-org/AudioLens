#!/bin/bash
# Assembles and signs AudioLens.app: Developer ID, hardened runtime, not sandboxed
# (it captures other apps' audio through Core Audio process taps).
#
#   ./build_app.sh [signing identity]
set -euo pipefail

APP_NAME="AudioLens"
BUNDLE_ID="com.smanke.AudioLens"
ROOT="$(cd "$(dirname "$0")" && pwd)"

IDENTITY="${1:-}"
BUILD_PATH="$ROOT/.build"
ENTITLEMENTS="$ROOT/Resources/AudioLens.entitlements"
BUILD="$ROOT/.build/app"
APP="$BUILD/$APP_NAME.app"
SWIFT_ARGS=(-c release --arch arm64 --arch x86_64 --build-path "$BUILD_PATH")

# Ask SwiftPM where it puts the binary rather than assuming: the location has moved
# between toolchains, and a hardcoded path once packaged a days-old binary inside a
# freshly versioned bundle. Delete it first, so the build has to write a new one; a
# checkout that only touched mtimes otherwise leaves SwiftPM skipping the link and the
# freshness check refusing to package.
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
rm -f "$BIN_DIR/$APP_NAME"
MARKER="$BUILD_PATH/.build-started"
mkdir -p "$BUILD_PATH"; touch "$MARKER"

echo "==> Building universal binary"
swift build "${SWIFT_ARGS[@]}"

if [ ! -x "$BIN_DIR/$APP_NAME" ]; then
  echo "No built binary at $BIN_DIR/$APP_NAME." >&2
  exit 1
fi
if [ -z "$(find "$BIN_DIR/$APP_NAME" -newer "$MARKER" -print -quit)" ]; then
  echo "$BIN_DIR/$APP_NAME wasn't rebuilt — refusing to package a stale binary." >&2
  exit 1
fi
echo "    using $BIN_DIR"

echo "==> Assembling bundle"
# Assembled beside the app, then copied over it in place: deleting and recreating the bundle
# orphans its System Audio Recording permission, even with the same signature.
STAGE="$BUILD/stage/$APP_NAME.app"
rm -rf "$BUILD/stage"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$STAGE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
mkdir -p "$APP"
rsync -a --delete "$STAGE/" "$APP/"
rm -rf "$BUILD/stage"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> Resolving signing identity"
if [ -z "$IDENTITY" ]; then
  FOUND=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
  if [ -z "$FOUND" ]; then
    echo "No Developer ID Application identity found in the keychain." >&2
    exit 1
  fi
  IDENTITY=$(echo "$FOUND" | sed -E 's/.*"(.*)"$/\1/')
fi
echo "    $IDENTITY"

echo "==> Signing"
# Keep the .entitlements files free of XML comments: plutil accepts them, but codesign's
# AMFI parser rejects the file ("syntax error near line 5").
codesign --force --options runtime --timestamp \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "Built $APP ($VERSION)"
