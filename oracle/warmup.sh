#!/bin/sh
# Warm-up series: captures NFOV unbinned + WFOV binned every ~2 minutes for ~30 minutes,
# streaming in between so the sensor warms. Then run the engine on each frame
# (oracle/run.sh) and our decoder (kinectctl decode --block --calibration), and
# compare same-scene frames with oracle/tempdiff.py. See docs/calibration-block.md,
# "Warm-up series". Output goes under oracle/in/warm (shared with Docker).
cd "$(dirname "$0")/.."
S=${WARM_DIR:-oracle/in/warm}
B=.build/release/kinectctl
for i in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
  D=$S/t$i
  mkdir -p $D
  date +%T > $D/time.txt
  OPENK4A_DECODER=cpu $B capture --mode nfov_unbinned --fps 30 --frames 3 --out $D/nfov --raw >> $D/log.txt 2>&1
  OPENK4A_DECODER=cpu $B capture --mode wfov_2x2binned --fps 30 --frames 3 --out $D/wfov --raw >> $D/log.txt 2>&1
  grep -h "temp=" $D/log.txt | tail -1
  # keep streaming ~100 s so it warms
  $B bench --color 720p --seconds 100 >/dev/null 2>&1
done
echo done > $S/done.txt
