#!/usr/bin/env python3
"""Compares a decoded depth plane (PGM from kinectctl decode) with the oracle's
(raw u16 from oracle/run.sh): validity agreement, error statistics by range,
and a histogram. Usage: compare.py ours.depth.pgm oracle.depth.u16 [width height]"""
import struct, sys

def read_pgm(path):
    data = open(path, 'rb').read()
    parts = data.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, struct.unpack('>%dH' % (w * h), parts[3][:w * h * 2])

def read_u16(path, n):
    return struct.unpack('<%dH' % n, open(path, 'rb').read()[:n * 2])

ours_path, oracle_path = sys.argv[1], sys.argv[2]
w, h, ours = read_pgm(ours_path)
oracle = read_u16(oracle_path, w * h)
n = w * h
both = only_ours = only_oracle = neither = 0
diffs = []
by_range = {}
for a, b in zip(ours, oracle):
    if a and b:
        both += 1
        d = a - b
        diffs.append(d)
        bucket = min(b // 500, 10)
        by_range.setdefault(bucket, []).append(d)
    elif a: only_ours += 1
    elif b: only_oracle += 1
    else: neither += 1
print(f"{w}x{h}: valid in both {both} ({100*both/n:.1f}%), only ours {only_ours} ({100*only_ours/n:.1f}%), only oracle {only_oracle} ({100*only_oracle/n:.1f}%), neither {neither}")
if diffs:
    diffs.sort()
    mean = sum(diffs) / len(diffs)
    rms = (sum(d * d for d in diffs) / len(diffs)) ** 0.5
    med = diffs[len(diffs) // 2]
    p = lambda q: diffs[int(q * (len(diffs) - 1))]
    print(f"ours - oracle (mm): mean {mean:+.2f} median {med:+d} rms {rms:.2f} p5 {p(0.05):+d} p95 {p(0.95):+d} min {diffs[0]:+d} max {diffs[-1]:+d}")
    bins = [(0, 0), (1, 1), (2, 2), (3, 5), (6, 10), (11, 20), (21, 50), (51, 100000)]
    print("|diff| histogram:", "  ".join(f"{lo}-{hi if hi < 100000 else 'inf'}:{sum(1 for d in diffs if lo <= abs(d) <= hi)}" for lo, hi in bins))
    print("by oracle range (m): " + "  ".join(f"{k*0.5:.1f}-{(k+1)*0.5:.1f}: n={len(v)} mean {sum(v)/len(v):+.1f} rms {(sum(d*d for d in v)/len(v))**0.5:.1f}" for k, v in sorted(by_range.items())))
