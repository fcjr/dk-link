#!/usr/bin/env python3
"""The app icon: a depth image. A sphere seen by the depth camera, coloured
by distance on the same ramp the app's colorized preview uses (warm near,
cool far), over the far, dark end of the ramp. Writes Resources/AppIcon.icns
and docs/icon.png. Needs numpy and macOS's sips/iconutil."""
import os, subprocess, sys
import numpy as np

def ramp(t):
    """The preview's ramp: red, yellow, green, cyan, blue over t in 0..1."""
    t = np.clip(t, 0, 1)
    r = np.clip(1.5 - np.abs(4 * t - 1), 0, 1) * np.where(t < 0.5, 1.0, np.clip(2 - 4 * t, 0, 1))
    g = np.clip(1.5 - np.abs(4 * t - 2), 0, 1)
    b = np.clip(1.5 - np.abs(4 * t - 3), 0, 1)
    return np.stack([r, g, b], axis=-1)

def render(size, scale=4):
    n = size * scale
    y, x = np.mgrid[0:n, 0:n]
    u = (x + 0.5) / n - 0.5
    v = (y + 0.5) / n - 0.5

    # macOS tile: a squircle.
    tile = (np.abs(u) ** 5 + np.abs(v) ** 5) <= 0.5 ** 5

    # The far field: the deep end of the ramp, darkened, dimmer toward the
    # corners the way the real illuminator is.
    rr = np.hypot(u, v)
    far = ramp(np.full_like(u, 0.96)) * 0.30
    far = far * (1 - 0.4 * np.clip(rr / 0.7, 0, 1) ** 2)[..., None]

    # The sphere: nearest at its centre, so the ramp runs from its warm end
    # at the centre to the cool end at the rim.
    cx, cy, R = 0.0, 0.0, 0.34
    d = np.hypot(u - cx, v - cy) / R
    inside = d < 1
    z = np.sqrt(np.clip(1 - d * d, 0, 1))
    t = 0.02 + 0.86 * (1 - z) ** 0.75
    sphere = ramp(t)
    # Iso-distance contours, the quantisation steps of a depth map.
    steps = 11.0
    phase = (t * steps) % 1.0
    contour = np.exp(-((np.minimum(phase, 1 - phase) * steps * R * n) ** 2) / (2 * (0.0035 * n) ** 2))
    sphere = sphere * (1 - 0.55 * contour)[..., None]
    rgb = np.where(inside[..., None], sphere, far)

    # At the sphere's edge the camera loses the grazing pixels: a thin black
    # ring of "no reading".
    halo = (d >= 1) & (d < 1.035)
    rgb = np.where(halo[..., None], 0.0, rgb)

    rgb = np.clip(rgb, 0, 1)
    a = tile.astype(np.float32)
    img = np.concatenate([rgb * a[..., None], a[..., None]], axis=-1)
    # Supersample down.
    img = img.reshape(size, scale, size, scale, 4).mean(axis=(1, 3))
    rgb, a = img[..., :3], img[..., 3:4]
    rgb = np.where(a > 0, rgb / np.maximum(a, 1e-6), 0)
    out = np.concatenate([rgb, a], axis=-1)
    return (np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8)

def write_png(path, pixels):
    import struct, zlib
    h, w, _ = pixels.shape
    raw = b"".join(b"\x00" + pixels[r].tobytes() for r in range(h))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

out = sys.argv[1] if len(sys.argv) > 1 else "Resources"
iconset = os.path.join(out, "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for size in (16, 32, 64, 128, 256, 512, 1024):
    pixels = render(size)
    write_png(os.path.join(iconset, f"icon_{size}x{size}.png"), pixels)
    if size >= 32:
        write_png(os.path.join(iconset, f"icon_{size//2}x{size//2}@2x.png"), pixels)
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(out, "AppIcon.icns")], check=True)
os.makedirs("docs", exist_ok=True)
write_png(os.path.join("docs", "icon.png"), render(256))
print("wrote", os.path.join(out, "AppIcon.icns"), "and docs/icon.png")
