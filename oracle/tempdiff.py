#!/usr/bin/env python3
"""Per-pixel change of (ours - engine) between two frames of the same scene: coarse map and
regression against candidate shapes. usage: tempdiff.py A.ours.pgm A.oracle.u16 B.ours.pgm B.oracle.u16 records.txt"""
import struct, sys, re, math
def pgm(p):
    b = open(p, 'rb').read(); parts = b.split(b'\n', 3); w, h = map(int, parts[1].split())
    return w, h, struct.unpack('>%dH' % (w * h), parts[3][:w * h * 2])
w, h, a_ours = pgm(sys.argv[1]); a_orc = struct.unpack('<%dH' % (w * h), open(sys.argv[2], 'rb').read()[:w * h * 2])
_, _, b_ours = pgm(sys.argv[3]); b_orc = struct.unpack('<%dH' % (w * h), open(sys.argv[4], 'rb').read()[:w * h * 2])
# spatial shape per frequency (mm per degree), as in spatialfit.py
rec = open(sys.argv[5]).read().splitlines(); sp = {}
for line in rec:
    m = re.match(r'mode 4 f(\d) spatial: .* rowT (\S+) (\S+) (\S+) (\S+) colT (.*?) simpleRow', line)
    if m: sp[int(m.group(1))] = ([float(v) for v in m.group(2, 3, 4, 5)], [float(v) for v in m.group(6).split()])
M = [22, 21, 6]; S2 = sum(x * x for x in M); alpha = [x * 3e8 / (2 * 9e6 * S2) * 1000 for x in M]
def poly5(c, x): return sum(c[k] * x ** k for k in range(5))
def spatial(row, col):
    s = 0.0
    for f in range(3):
        rtc, ctc = sp[f]; theta = 0.01 * (col * rtc[3] / w + poly5(ctc[5:10], row / h) + rtc[1]); s += alpha[f] * theta / (2 * math.pi)
    return s
gc, gr = 8, 6; cells = [[[] for _ in range(gc)] for _ in range(gr)]
X = []  # rows: [1, spatial, range_m, col/w, row/h]
Y = []
for y in range(0, h, 2):
    for x in range(0, w, 2):
        i = y * w + x
        if a_ours[i] and a_orc[i] and b_ours[i] and b_orc[i] and abs(int(a_orc[i]) - int(b_orc[i])) < 30:  # same scene content
            d = (int(b_ours[i]) - int(b_orc[i])) - (int(a_ours[i]) - int(a_orc[i]))
            cells[y * gr // h][x * gc // w].append(d)
            X.append([1.0, spatial(y, x), a_orc[i] / 1000.0, x / w, y / h]); Y.append(float(d))
print("change map (B - A), mm:")
for row in cells:
    print("".join(("%+6.2f " % (sorted(c)[len(c) // 2])) if len(c) >= 200 else "   .   " for c in row))
# least squares with numpy-free normal equations
import itertools
def lstsq(cols):
    k = len(cols); A = [[sum(X[i][p] * X[i][q] for i in range(len(X))) for q in cols] for p in cols]; bvec = [sum(X[i][p] * Y[i] for i in range(len(X))) for p in cols]
    # gaussian elimination
    n = k; Mx = [A[r][:] + [bvec[r]] for r in range(n)]
    for c in range(n):
        piv = max(range(c, n), key=lambda r: abs(Mx[r][c])); Mx[c], Mx[piv] = Mx[piv], Mx[c]
        for r in range(n):
            if r != c and Mx[c][c] != 0:
                f = Mx[r][c] / Mx[c][c]; Mx[r] = [Mx[r][j] - f * Mx[c][j] for j in range(n + 1)]
    coef = [Mx[r][n] / Mx[r][r] for r in range(n)]
    res = (sum((Y[i] - sum(coef[j] * X[i][cols[j]] for j in range(k))) ** 2 for i in range(len(Y))) / len(Y)) ** 0.5
    return coef, res
tot = (sum((y - sum(Y) / len(Y)) ** 2 for y in Y) / len(Y)) ** 0.5
print("pixels %d, change rms about mean %.2f mm (mean %+.2f)" % (len(Y), tot, sum(Y) / len(Y)))
for name, cols in [("const+spatial", [0, 1]), ("const+range", [0, 2]), ("const+col+row", [0, 3, 4]), ("const+spatial+range", [0, 1, 2]), ("all", [0, 1, 2, 3, 4])]:
    coef, res = lstsq(cols); print("  %-20s coef %s residual rms %.2f" % (name, ["%+.3f" % c for c in coef], res))
