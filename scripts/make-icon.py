#!/usr/bin/env python3
"""Draws the app icon (a depth-camera glyph) as PNGs and packs an .icns.
No image libraries needed: pixels are written straight into PNG."""
import math, os, struct, subprocess, sys, zlib

def png(path, size, pixel):
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            row += bytes(pixel(x, y, size))
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def icon_pixel(x, y, size):
    # Rounded dark tile, a wide camera body, a bright depth "ring" and a warm IR dot.
    u, v = (x + 0.5) / size, (y + 0.5) / size
    r = 0.22
    def inside_rounded(u, v, r):
        cx = min(max(u, r), 1 - r); cy = min(max(v, r), 1 - r)
        return (u - cx) ** 2 + (v - cy) ** 2 <= r * r
    if not inside_rounded(u, v, r):
        return (0, 0, 0, 0)
    # background gradient
    g = 0.5 + 0.5 * (1 - v)
    base = (int(18 + 20 * g), int(22 + 30 * g), int(36 + 50 * g), 255)
    # camera body: a wide bar
    if 0.18 <= u <= 0.82 and 0.40 <= v <= 0.62:
        base = (54, 60, 72, 255)
    # depth lens: concentric rings
    d = math.hypot((u - 0.38) * 1.0, (v - 0.51) * 1.0)
    if d < 0.085:
        t = d / 0.085
        ring = 0.5 + 0.5 * math.cos(t * math.pi * 4)
        base = (int(40 + 60 * ring), int(140 + 90 * ring), int(220 + 30 * ring), 255)
    # colour lens
    d2 = math.hypot(u - 0.62, v - 0.51)
    if d2 < 0.06:
        base = (235, 240, 245, 255) if d2 > 0.045 else (30, 30, 36, 255)
    # IR illuminator dot
    d3 = math.hypot(u - 0.735, v - 0.51)
    if d3 < 0.022:
        base = (255, 120, 60, 255)
    # a soft depth cone below, hinting at the field of view
    if v > 0.62 and abs(u - 0.38) < (v - 0.62) * 1.1 and v < 0.92:
        a = max(0.0, 1 - (v - 0.62) / 0.3)
        base = (int(base[0] * (1 - 0.35 * a) + 80 * 0.35 * a), int(base[1] * (1 - 0.35 * a) + 180 * 0.35 * a), int(base[2] * (1 - 0.35 * a) + 240 * 0.35 * a), 255)
    return base

out = sys.argv[1] if len(sys.argv) > 1 else "Resources"
iconset = os.path.join(out, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for size in (16, 32, 64, 128, 256, 512, 1024):
    png(os.path.join(iconset, f"icon_{size}x{size}.png"), size, icon_pixel)
    if size <= 512:
        png(os.path.join(iconset, f"icon_{size//2}x{size//2}@2x.png"), size, icon_pixel)
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(out, "AppIcon.icns")], check=True)
print("wrote", os.path.join(out, "AppIcon.icns"))
