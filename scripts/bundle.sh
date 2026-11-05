#!/bin/sh
# Builds DK Link.app from the SwiftPM release build.
#   scripts/bundle.sh [--sign "Developer ID Application: ..."] [--out dir] [--dmg]
# With --sign and --notarize <keychain-profile>, the app and the DMG are
# notarized and stapled. --notarize api reads an App Store Connect API key from
# NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER instead. Releases are built by .github/workflows/release.yml.
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
notarize() {
  if [ "$NOTARIZE" = api ]; then
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "$NOTARIZE" --wait
  fi
}
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
STAMP="$VERSION+$(git rev-parse --short HEAD 2>/dev/null || echo local)"
swift build -c release --product DKLinkApp
swift build -c release --product DKLinkTD
swift build -c release --product dklink
BIN="$(swift build -c release --show-bin-path)"
APP="$OUT/DK Link.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DKLinkApp" "$APP/Contents/MacOS/DK Link"
# The command-line tool rides along so Sparkle updates it with the app and the
# Homebrew cask can link it onto PATH.
cp "$BIN/dklink" "$APP/Contents/MacOS/dklink"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
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
  <key>SUFeedURL</key><string>https://raw.githubusercontent.com/fcjr/dk-link/main/appcast.xml</string>
  <key>SUPublicEDKey</key><string>eLvy63Rl08HgPjifRJqvtgRLAVLVEY5ytZxkgscftyo=</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# The TouchDesigner plugins ride inside the app as resources (a loose VERSION
# file is not allowed under PlugIns); they are signed before the app, and the app
# installs them from there.
mkdir -p "$APP/Contents/Resources/TouchDesigner"
touchdesigner/plugin/build.sh --lib "$BIN/libDKLinkTD.dylib" --out "$(cd "$APP/Contents/Resources/TouchDesigner" && pwd)" --stamp "$STAMP" >/dev/null
[ -f "$APP/Contents/Resources/TouchDesigner/DK Link/VERSION" ] || { echo "TouchDesigner plugin did not build" >&2; exit 1; }
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
  # Inside out, no --deep: Sparkle's helpers keep their own entitlements and
  # only the app and the CLI get the camera/USB ones.
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN" "$@"; }
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$SPARKLE/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Autoupdate"
  sign "$SPARKLE/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  TD="$APP/Contents/Resources/TouchDesigner/DK Link"
  sign "$TD/DKLinkTOP.plugin/Contents/Frameworks/libDKLinkTD.dylib"
  sign "$TD/DKLinkTOP.plugin"
  sign "$TD/DKLinkCHOP.plugin"
  sign --entitlements "$OUT/entitlements.plist" "$APP/Contents/MacOS/dklink"
  sign --entitlements "$OUT/entitlements.plist" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "built $APP"
if [ -n "$NOTARIZE" ]; then
  # Staple the app itself too, so a copy Sparkle installs verifies offline.
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
fi
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
    notarize "$DMGPATH"
    xcrun stapler staple "$DMGPATH"
  fi
  echo "built $DMGPATH"
fi
