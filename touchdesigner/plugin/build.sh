#!/bin/sh
# Builds the Kinect Azure TOP and CHOP plugins for TouchDesigner (macOS).
#
#   touchdesigner/plugin/build.sh [--lib path/to/libKinectTD.dylib] [--stub] [--install]
#
# --stub   links the stub library (synthetic images, one fake body) instead of
#          the real one, for testing the operators without a camera.
# --lib    the real library (default: the newest libKinectTD.dylib under .build).
# --install copies the result to ~/Library/Application Support/Derivative/TouchDesigner099/Plugins/Kinect Azure/
#
# Layout (one folder, so the two bundles share ONE copy of the library and
# therefore one camera session):
#   Kinect Azure/
#     KinectAzureTOP.plugin/Contents/{MacOS/KinectAzureTOP, Frameworks/libKinectTD.dylib, Info.plist}
#     KinectAzureCHOP.plugin/Contents/{MacOS/KinectAzureCHOP, Info.plist}   (rpath -> the TOP's Frameworks)
set -eu
cd "$(dirname "$0")"
PLUGIN_DIR="$(pwd)"
ROOT="$(cd ../.. && pwd)"
OUT="$PLUGIN_DIR/build/Kinect Azure"
LIB=""
STUB=0
INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lib) LIB="$2"; shift 2 ;;
    --stub) STUB=1; shift ;;
    --install) INSTALL=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

MIN=12.0
CXX="clang++ -std=c++17 -O2 -mmacosx-version-min=$MIN -DMACOS -I$PLUGIN_DIR -I$PLUGIN_DIR/sdk"

mkdir -p "$PLUGIN_DIR/build/stub"
if [ "$STUB" = 1 ]; then
  clang -O2 -mmacosx-version-min=$MIN -dynamiclib -install_name @rpath/libKinectTD.dylib \
    -I"$PLUGIN_DIR" -o "$PLUGIN_DIR/build/stub/libKinectTD.dylib" "$PLUGIN_DIR/stub/kinecttd_stub.c"
  LIB="$PLUGIN_DIR/build/stub/libKinectTD.dylib"
elif [ -z "$LIB" ]; then
  LIB="$(ls -t "$ROOT"/.build/*/release/libKinectTD.dylib "$ROOT"/.build/release/libKinectTD.dylib 2>/dev/null | head -1 || true)"
  if [ -z "$LIB" ]; then
    echo "no libKinectTD.dylib found; build it with 'swift build -c release --product KinectTD' or pass --stub" >&2
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
  <key>CFBundleIdentifier</key><string>com.frankchiarulli.kinect-for-mac.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
}

bundle KinectAzureTOP
mkdir -p "$OUT/KinectAzureTOP.plugin/Contents/Frameworks"
cp "$LIB" "$OUT/KinectAzureTOP.plugin/Contents/Frameworks/libKinectTD.dylib"
install_name_tool -id @rpath/libKinectTD.dylib "$OUT/KinectAzureTOP.plugin/Contents/Frameworks/libKinectTD.dylib" 2>/dev/null || true
$CXX -bundle -o "$OUT/KinectAzureTOP.plugin/Contents/MacOS/KinectAzureTOP" \
  "$PLUGIN_DIR/KinectAzureTOP.cpp" \
  "$OUT/KinectAzureTOP.plugin/Contents/Frameworks/libKinectTD.dylib" \
  -Wl,-rpath,@loader_path/../Frameworks

bundle KinectAzureCHOP
$CXX -bundle -o "$OUT/KinectAzureCHOP.plugin/Contents/MacOS/KinectAzureCHOP" \
  "$PLUGIN_DIR/KinectAzureCHOP.cpp" \
  "$OUT/KinectAzureTOP.plugin/Contents/Frameworks/libKinectTD.dylib" \
  -Wl,-rpath,@loader_path/../../../KinectAzureTOP.plugin/Contents/Frameworks

for b in KinectAzureTOP KinectAzureCHOP; do
  codesign --force --deep --sign - "$OUT/$b.plugin"
done
echo "built: $OUT"
otool -L "$OUT/KinectAzureCHOP.plugin/Contents/MacOS/KinectAzureCHOP" | grep KinectTD

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Library/Application Support/Derivative/TouchDesigner099/Plugins"
  mkdir -p "$DEST"
  rm -rf "$DEST/Kinect Azure"
  cp -R "$OUT" "$DEST/Kinect Azure"
  echo "installed: $DEST/Kinect Azure"
fi
