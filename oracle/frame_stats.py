#!/usr/bin/env python3
"""Per-frame comparison of our decode with the engine, with the footer temperatures.
usage: analyze.py <raw> <ours.depth.pgm> <oracle.depth.u16>"""
import struct, sys
raw, ours_path, oracle_path = sys.argv[1:4]
d = open(raw, 'rb').read()
foot = d[-40:]
exposure = struct.unpack('<Q', foot[8:16])[0]
sensor_t, laser0, laser1 = struct.unpack('<fff', foot[16:28])
def pgm(p):
    b = open(p, 'rb').read(); parts = b.split(b'\n', 3); w, h = map(int, parts[1].split())
    return w, h, struct.unpack('>%dH' % (w * h), parts[3][:w * h * 2])
w, h, ours = pgm(ours_path)
orc = struct.unpack('<%dH' % (w * h), open(oracle_path, 'rb').read()[:w * h * 2])
diffs = []; by_range = {}
both = only_ours = only_orc = 0
for a, b in zip(ours, orc):
    if a and b:
        both += 1; dd = a - b; diffs.append(dd)
        by_range.setdefault(min(b // 500, 8), []).append(dd)
    elif a: only_ours += 1
    elif b: only_orc += 1
diffs.sort()
n = len(diffs)
mean = sum(diffs) / n; rms = (sum(x * x for x in diffs) / n) ** 0.5
# trimmed mean (middle 80%) is the robust bias
trim = diffs[n // 10: n - n // 10]; tmean = sum(trim) / len(trim)
ranges = " ".join("%d-%d:%+.2f" % (k * 500, (k + 1) * 500, sum(v) / len(v)) for k, v in sorted(by_range.items()) if len(v) > 500)
print("sensor %.2f laser %.2f/%.2f exp %d both %d ours+ %d orc+ %d bias %+.3f trimmed %+.3f rms %.2f | %s" % (
    sensor_t, laser0, laser1, exposure, both, only_ours, only_orc, mean, tmean, rms, ranges))
