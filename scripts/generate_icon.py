#!/usr/bin/env python3
"""Generate ARIFA launcher icons without any external image library."""

import math
import os
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FONT = {
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
}


class Canvas:
    def __init__(self, size):
        self.size = size
        self.px = bytearray(size * size * 4)

    def blend(self, x, y, rgb, alpha=255):
        x, y = int(x), int(y)
        if x < 0 or y < 0 or x >= self.size or y >= self.size:
            return
        sa = max(0, min(255, int(alpha))) / 255.0
        if sa <= 0:
            return
        i = (y * self.size + x) * 4
        oa = self.px[i + 3] / 255.0
        na = sa + oa * (1 - sa)
        if na <= 0:
            return
        for c in range(3):
            old = self.px[i + c]
            self.px[i + c] = int((rgb[c] * sa + old * oa * (1 - sa)) / na)
        self.px[i + 3] = int(na * 255)

    def ellipse(self, cx, cy, rx, ry, rgb, alpha=255):
        for y in range(max(0, int(cy - ry)), min(self.size, int(cy + ry) + 1)):
            for x in range(max(0, int(cx - rx)), min(self.size, int(cx + rx) + 1)):
                if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1:
                    self.blend(x, y, rgb, alpha)

    def line(self, x0, y0, x1, y1, rgb, alpha=255, width=1):
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(steps + 1):
            x = x0 + (x1 - x0) * i / steps
            y = y0 + (y1 - y0) * i / steps
            for dx in range(-width // 2, width // 2 + 1):
                for dy in range(-width // 2, width // 2 + 1):
                    self.blend(x + dx, y + dy, rgb, alpha)

    def text(self, word, scale, x0, y0, rgb, alpha=255):
        cell = 5 * scale
        advance = 6 * scale
        for li, ch in enumerate(word):
            rows = FONT.get(ch, FONT["A"])
            for r, row in enumerate(rows):
                for c, bit in enumerate(row):
                    if bit == "1":
                        for dy in range(scale):
                            for dx in range(scale):
                                self.blend(
                                    x0 + li * advance + c * scale + dx,
                                    y0 + r * scale + dy,
                                    rgb,
                                    alpha,
                                )


def draw_icon(size, round_mask=False):
    c = Canvas(size)
    cx = cy = size / 2

    # Dark blue radial gradient.
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / (size / 2)
            k = max(0.0, 1.0 - d)
            rgb = (2 + int(7 * k), 10 + int(28 * k), 24 + int(66 * k))
            c.blend(x, y, rgb, 255)

    # Arc-reactor halo.
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / (size / 2)
            glow = max(0.0, 1.0 - abs(d - 0.40) / 0.10)
            core = max(0.0, 1.0 - abs(d - 0.40) / 0.018)
            if glow > 0:
                c.blend(x, y, (0, 180, 255), int(glow * 55))
            if core > 0:
                c.blend(x, y, (120, 240, 255), int(core * 220))

    # Hair, then face.
    hair_r = size * 0.235
    c.ellipse(cx, size * 0.365, hair_r, hair_r * 1.12, (12, 18, 42), 255)
    c.ellipse(cx, size * 0.375, size * 0.175, size * 0.19, (244, 197, 164), 255)

    # Bangs.
    c.ellipse(cx, size * 0.255, size * 0.178, size * 0.075, (12, 18, 42), 255)

    # Eyes.
    ex = size * 0.068
    ey = size * 0.375
    for s in (-1, 1):
        ecx = cx + s * size * 0.072
        c.ellipse(ecx, ey, ex * 0.48, ex * 0.36, (255, 255, 255), 255)
        c.ellipse(ecx + size * 0.006, ey, ex * 0.22, ex * 0.25, (58, 34, 24), 255)
        c.blend(ecx + size * 0.002, ey - size * 0.010, (255, 255, 255), 255)

    # Smile.
    for i in range(size // 2):
        u = -1 + 2 * i / max(1, size // 2 - 1)
        x = cx + u * size * 0.060
        y = size * 0.435 + size * 0.018 * (1 - u * u)
        c.blend(x, y, (140, 53, 80), 220)

    # Necklace core.
    c.ellipse(cx, size * 0.575, size * 0.035, size * 0.035, (0, 190, 255), 90)
    c.ellipse(cx, size * 0.575, size * 0.018, size * 0.018, (255, 255, 255), 255)

    # Neon ARIFA text with glow.
    scale = max(1, size // 64)
    word = "ARIFA"
    width = len(word) * 6 * scale - scale
    tx = int((size - width) / 2)
    ty = int(size * 0.67)
    for ox in (-2, 2):
        for oy in (-2, 2):
            c.text(word, scale, tx + ox, ty + oy, (0, 190, 255), 45)
    c.text(word, scale, tx, ty, (190, 250, 255), 255)

    if round_mask:
        for y in range(size):
            for x in range(size):
                d = math.hypot(x - cx, y - cy) / (size / 2)
                i = (y * size + x) * 4
                if d >= 1.0:
                    c.px[i + 3] = 0
                elif d > 0.985:
                    c.px[i + 3] = int(c.px[i + 3] * (1.0 - d) / 0.015)

    return c.px


def chunk(tag, data):
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def write_png(path, size, pixels):
    raw = b"".join(
        b"\x00" + bytes(pixels[y * size * 4 : (y + 1) * size * 4])
        for y in range(size)
    )
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main():
    densities = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for name, size in densities.items():
        res = ROOT / "android" / "app" / "src" / "main" / "res" / f"mipmap-{name}"
        write_png(res / "ic_launcher.png", size, draw_icon(size))
        write_png(res / "ic_launcher_round.png", size, draw_icon(size, True))

    write_png(ROOT / "assets" / "icon" / "arifa_icon.png", 512, draw_icon(512))
    print("ARIFA launcher icons generated.")


if __name__ == "__main__":
    main()
