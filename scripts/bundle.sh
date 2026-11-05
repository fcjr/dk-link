#!/bin/sh
# Builds DK Link.app from the SwiftPM release build.
#   scripts/bundle.sh [--sign "Developer ID Application: ..."] [--out dir] [--dmg]
# With --sign and --notarize <keychain-profile>, the DMG is notarized and stapled.
set -eu
cd "$(dirname "$0")/.."
SIGN=""
OUT="dist"
DMG=0
NOTARIZE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) SIGN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --dmg) DMG=1; shift ;;
    --notarize) NOTARIZE="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
STAMP="$VERSION+$(git rev-parse --short HEAD 2>/dev/null || echo local)"
swift build -c release --product DKLinkApp
swift build -c release --product DKLinkTD
BIN="$(swift build -c release --show-bin-path)"
APP="$OUT/DK Link.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DKLinkApp" "$APP/Contents/MacOS/DK Link"
# SwiftPM resource bundles the app loads at run time.
for bundle in "$BIN"/*.bundle; do
  case "$bundle" in *Tests.bundle) continue ;; esac
  [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DK Link</string>
  <key>CFBundleDisplayName</key><string>DK Link</string>
  <key>CFBundleIdentifier</key><string>com.leftshift.dklink</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>DK Link</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSCameraUsageDescription</key><string>DK Link reads the Azure Kinect's colour camera.</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Left Shift Logical, LLC. MIT License. Not affiliated with Microsoft; Azure Kinect is a trademark of Microsoft Corporation.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# The TouchDesigner plugins ride inside the app (Contents/PlugIns, a code
# location, so --deep signing covers them); the app installs them from there.
mkdir -p "$APP/Contents/PlugIns/TouchDesigner"
touchdesigner/plugin/build.sh --lib "$BIN/libDKLinkTD.dylib" --out "$(cd "$APP/Contents/PlugIns/TouchDesigner" && pwd)" --stamp "$STAMP" >/dev/null
[ -f "$APP/Contents/PlugIns/TouchDesigner/DK Link/VERSION" ] || { echo "TouchDesigner plugin did not build" >&2; exit 1; }
cat > "$OUT/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.device.usb</key><true/>
</dict>
</plist>
PLIST
if [ -n "$SIGN" ]; then
  codesign --force --deep --options runtime --timestamp --entitlements "$OUT/entitlements.plist" --sign "$SIGN" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "built $APP"
if [ "$DMG" = 1 ]; then
  DMGPATH="$OUT/DK-Link-$VERSION.dmg"
  STAGE="$OUT/dmg-stage"
  rm -rf "$STAGE" "$DMGPATH"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "DK Link" -srcfolder "$STAGE" -ov -format UDZO "$DMGPATH" >/dev/null
  rm -rf "$STAGE"
  if [ -n "$SIGN" ]; then
    codesign --force --timestamp --sign "$SIGN" "$DMGPATH"
  fi
  if [ -n "$NOTARIZE" ]; then
    xcrun notarytool submit "$DMGPATH" --keychain-profile "$NOTARIZE" --wait
    xcrun stapler staple "$DMGPATH"
  fi
  echo "built $DMGPATH"
fi
