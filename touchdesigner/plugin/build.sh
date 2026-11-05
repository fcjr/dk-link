#!/bin/sh
# Builds the DK Link TOP and CHOP plugins for TouchDesigner (macOS).
#
#   touchdesigner/plugin/build.sh [--lib path/to/libDKLinkTD.dylib] [--stub] [--install] [--out dir] [--stamp text]
#
# --out    where to write the "DK Link" folder (default: touchdesigner/plugin/build).
# --stamp  writes the text into DK Link/VERSION, which the app's installer compares.
#
# --stub   links the stub library (synthetic images, one fake body) instead of
#          the real one, for testing the operators without a camera.
# --lib    the real library (default: the newest libDKLinkTD.dylib under .build).
# --install copies the result to ~/Library/Application Support/Derivative/TouchDesigner099/Plugins/DK Link/
#
# Layout (one folder, so the two bundles share ONE copy of the library and
# therefore one camera session):
#   DK Link/
#     DKLinkTOP.plugin/Contents/{MacOS/DKLinkTOP, Frameworks/libDKLinkTD.dylib, Info.plist}
#     DKLinkCHOP.plugin/Contents/{MacOS/DKLinkCHOP, Info.plist}   (rpath -> the TOP's Frameworks)
set -eu
cd "$(dirname "$0")"
PLUGIN_DIR="$(pwd)"
ROOT="$(cd ../.. && pwd)"
OUT="$PLUGIN_DIR/build/DK Link"
LIB=""
STUB=0
INSTALL=0
STAMP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lib) LIB="$2"; shift 2 ;;
    --stub) STUB=1; shift ;;
    --install) INSTALL=1; shift ;;
    --out) OUT="$(mkdir -p "$2" && cd "$2" && pwd)/DK Link"; shift 2 ;;
    --stamp) STAMP="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

MIN=12.0
CXX="clang++ -std=c++17 -O2 -mmacosx-version-min=$MIN -DMACOS -I$PLUGIN_DIR -I$PLUGIN_DIR/sdk"

mkdir -p "$PLUGIN_DIR/build/stub"
if [ "$STUB" = 1 ]; then
  clang -O2 -mmacosx-version-min=$MIN -dynamiclib -install_name @rpath/libDKLinkTD.dylib \
    -I"$PLUGIN_DIR" -o "$PLUGIN_DIR/build/stub/libDKLinkTD.dylib" "$PLUGIN_DIR/stub/dklinktd_stub.c"
  LIB="$PLUGIN_DIR/build/stub/libDKLinkTD.dylib"
elif [ -z "$LIB" ]; then
  LIB="$(ls -t "$ROOT"/.build/*/release/libDKLinkTD.dylib "$ROOT"/.build/release/libDKLinkTD.dylib 2>/dev/null | head -1 || true)"
  if [ -z "$LIB" ]; then
    echo "no libDKLinkTD.dylib found; build it with 'swift build -c release --product DKLinkTD' or pass --stub" >&2
    exit 1
  fi
fi
echo "library: $LIB"

bundle() {
  name="$1"; shift
  dir="$OUT/$name.plugin/Contents"
  rm -rf "$OUT/$name.plugin"
  mkdir -p "$dir/MacOS"
  cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>com.leftshift.dklink.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Left Shift Logical, LLC. MIT License.</string>
</dict>
</plist>
PLIST
}

bundle DKLinkTOP
mkdir -p "$OUT/DKLinkTOP.plugin/Contents/Frameworks"
cp "$LIB" "$OUT/DKLinkTOP.plugin/Contents/Frameworks/libDKLinkTD.dylib"
install_name_tool -id @rpath/libDKLinkTD.dylib "$OUT/DKLinkTOP.plugin/Contents/Frameworks/libDKLinkTD.dylib" 2>/dev/null || true
$CXX -bundle -o "$OUT/DKLinkTOP.plugin/Contents/MacOS/DKLinkTOP" \
  "$PLUGIN_DIR/DKLinkTOP.cpp" \
  "$OUT/DKLinkTOP.plugin/Contents/Frameworks/libDKLinkTD.dylib" \
  -Wl,-rpath,@loader_path/../Frameworks

bundle DKLinkCHOP
$CXX -bundle -o "$OUT/DKLinkCHOP.plugin/Contents/MacOS/DKLinkCHOP" \
  "$PLUGIN_DIR/DKLinkCHOP.cpp" \
  "$OUT/DKLinkTOP.plugin/Contents/Frameworks/libDKLinkTD.dylib" \
  -Wl,-rpath,@loader_path/../../../DKLinkTOP.plugin/Contents/Frameworks

for b in DKLinkTOP DKLinkCHOP; do
  codesign --force --deep --sign - "$OUT/$b.plugin"
done
if [ -n "$STAMP" ]; then
  printf '%s\n' "$STAMP" > "$OUT/VERSION"
fi
echo "built: $OUT"
otool -L "$OUT/DKLinkCHOP.plugin/Contents/MacOS/DKLinkCHOP" | grep DKLinkTD

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Library/Application Support/Derivative/TouchDesigner099/Plugins"
  mkdir -p "$DEST"
  rm -rf "$DEST/DK Link"
  cp -R "$OUT" "$DEST/DK Link"
  echo "installed: $DEST/DK Link"
fi
