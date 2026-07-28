#!/bin/zsh
# Builds MacClip.app (universal) and packages it into a DMG.
# Usage: scripts/make_dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
DIST="$ROOT/dist"
APP="$DIST/MacClip.app"
DMG="$DIST/MacClip-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Building universal binary"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"
cp "$ROOT/.build/apple/Products/Release/macclip" "$APP/Contents/MacOS/macclip"

echo "==> Assembling bundle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

echo "==> Icon"
ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make_icon.swift" "$DIST/icon-1024.png" 1024
for size in 16 32 128 256 512; do
  sips -z $size $size "$DIST/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$DIST/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> DMG"
STAGE="$DIST/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacClip $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE" "$ICONSET" "$DIST/icon-1024.png"

echo "==> Done: $DMG"
shasum -a 256 "$DMG"
