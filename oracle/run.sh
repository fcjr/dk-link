#!/bin/sh
# oracle/run.sh <mode> <frame.raw> <out-prefix under the repo> [camera-calibration.bin]
# Uses the fixture calibration block. Writes <out-prefix>.depth.u16, .ir.u16 and
# .info.txt from Microsoft's engine. Pass the depth camera's calibration as the
# SDK does (dklink camera-calibration calibration.json out.bin --raw; the
# fixture copy is Tests/DKCoreTests/Fixtures/depth_camera_calibration.bin):
# without it the engine falls back to the block's own intrinsics and its Z
# differs from the SDK's by up to 15 mm at range. ORACLE_OUTPUT=radial gives
# the radial distance instead of Z.
set -eu
cd "$(dirname "$0")/.."
# Microsoft's engine is not in this repository: it is fetched from Microsoft's
# own package server (the Ubuntu 18.04 arm64 libk4a1.4 package) on first use.
ENGINE=oracle/engine/libdepthengine.so.2.0
if [ ! -f "$ENGINE" ]; then
  mkdir -p oracle/engine oracle/engine/deb
  DEB_URL="https://packages.microsoft.com/ubuntu/18.04/multiarch/prod/pool/main/libk/libk4a1.4/libk4a1.4_1.4.2_arm64.deb"
  curl -fsSL -o oracle/engine/deb/libk4a1.4.deb "$DEB_URL"
  (cd oracle/engine/deb && ar x libk4a1.4.deb && tar xf data.tar.* ./usr/lib/aarch64-linux-gnu/libk4a1.4/libdepthengine.so.2.0)
  cp oracle/engine/deb/usr/lib/aarch64-linux-gnu/libk4a1.4/libdepthengine.so.2.0 "$ENGINE"
fi
docker image inspect k4a-oracle >/dev/null 2>&1 || docker build --platform linux/arm64 -t k4a-oracle oracle
MODE="$1"; RAW="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; OUT="$3"
CAMCAL="${4:-}"; CAMARG=""; CAMMOUNT=""
if [ -n "$CAMCAL" ]; then CAMABS="$(cd "$(dirname "$CAMCAL")" && pwd)/$(basename "$CAMCAL")"; CAMMOUNT="-v $CAMABS:/in/camera.bin:ro"; CAMARG="/in/camera.bin"; fi
mkdir -p "$(dirname "$OUT")"
OUTDIR="$(cd "$(dirname "$OUT")" && pwd)"
docker run --rm --platform linux/arm64 --entrypoint sh \
  -e ORACLE_OUTPUT="${ORACLE_OUTPUT:-z}" $CAMMOUNT \
  -v "$RAW:/in/frame.raw:ro" \
  -v "$(pwd)/Tests/DKCoreTests/Fixtures/calibration_block.bin:/in/block.bin:ro" \
  -v "$OUTDIR:/out" \
  k4a-oracle -c 'Xvfb :99 -screen 0 1280x1024x24 +extension GLX -nolisten tcp >/dev/null 2>&1 & sleep 2; DISPLAY=:99 exec timeout 600 /oracle/oracle "$@"' sh \
  "$MODE" /in/block.bin /in/frame.raw "/out/$(basename "$OUT")" $CAMARG
