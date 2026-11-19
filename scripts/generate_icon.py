#!/usr/bin/env python3
"""Generate ARIFA launcher icons from assets/icon/arifa_icon.png.

Stdlib only. When the master PNG is present every mipmap is derived from it;
when it is missing it is drawn once from the in-memory fallback and saved.
"""

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ICON = ROOT / "assets" / "icon" / "arifa_icon.png"

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
    """Fallback drawing, used only to create the master PNG when it is absent."""
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
        return apply_round_mask(c.px, size)
    return c.px


# --- PNG input/output -----------------------------------------------------


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
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unpack_samples(row, width, bit_depth, channels):
    if bit_depth == 8:
        return [row[i] for i in range(width * channels)]
    if bit_depth == 16:
        return [row[i * 2] for i in range(width * channels)]
    per_byte = 8 // bit_depth
    mask = (1 << bit_depth) - 1
    out = []
    for byte in row:
        for shift in range(8 - bit_depth, -1, -bit_depth):
            out.append((byte >> shift) & mask)
    return out[: width * channels]


def read_png(path):
    """Decode a non-interlaced PNG into (width, height, RGBA bytearray)."""
    path = Path(path)
    blob = path.read_bytes()
    if not blob.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"Not a PNG file: {path}")
    pos = 8
    width = height = bit_depth = color_type = interlace = None
    palette = b""
    transparent = b""
    idat = bytearray()
    while pos + 12 <= len(blob):
        length = struct.unpack(">I", blob[pos : pos + 4])[0]
        tag = blob[pos + 4 : pos + 8]
        data = blob[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            (
                width,
                height,
                bit_depth,
                color_type,
                _compression,
                _filter,
                interlace,
            ) = struct.unpack(">IIBBBBB", data)
        elif tag == b"PLTE":
            palette = data
        elif tag == b"tRNS":
            transparent = data
        elif tag == b"IDAT":
            idat.extend(data)
        elif tag == b"IEND":
            break
    if not width or not height:
        raise ValueError(f"PNG has no IHDR: {path}")
    if interlace != 0:
        raise ValueError(f"Interlaced PNGs are not supported: {path}")
    if bit_depth not in (1, 2, 4, 8, 16):
        raise ValueError(f"Unsupported PNG bit depth {bit_depth}: {path}")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type)
    if channels is None:
        raise ValueError(f"Unsupported PNG colour type {color_type}: {path}")
    if color_type == 3 and not palette:
        raise ValueError(f"Palette PNG without PLTE: {path}")

    raw = zlib.decompress(bytes(idat))
    row_bytes = (width * channels * bit_depth + 7) // 8
    filter_bytes = max(1, (channels * bit_depth + 7) // 8)
    gray_scale = 255 / ((1 << bit_depth) - 1) if bit_depth < 8 else 1
    trns_gray = None
    if len(transparent) >= 2:
        trns_gray = transparent[0] if bit_depth == 16 else transparent[1]
    trns_rgb = None
    if len(transparent) >= 6:
        trns_rgb = tuple(transparent[i] for i in (0, 2, 4))

    pos = 0
    prev = bytearray(row_bytes)
    out = bytearray(width * height * 4)
    for y in range(height):
        if pos + row_bytes + 1 > len(raw):
            raise ValueError(f"Truncated PNG image data: {path}")
        filter_type = raw[pos]
        row = bytearray(raw[pos + 1 : pos + 1 + row_bytes])
        pos += 1 + row_bytes
        if filter_type == 1:
            for i in range(filter_bytes, row_bytes):
                row[i] = (row[i] + row[i - filter_bytes]) & 255
        elif filter_type == 2:
            for i in range(row_bytes):
                row[i] = (row[i] + prev[i]) & 255
        elif filter_type == 3:
            for i in range(row_bytes):
                left = row[i - filter_bytes] if i >= filter_bytes else 0
                row[i] = (row[i] + ((left + prev[i]) // 2)) & 255
        elif filter_type == 4:
            for i in range(row_bytes):
                left = row[i - filter_bytes] if i >= filter_bytes else 0
                upper_left = prev[i - filter_bytes] if i >= filter_bytes else 0
                row[i] = (row[i] + _paeth(left, prev[i], upper_left)) & 255
        elif filter_type != 0:
            raise ValueError(f"Unsupported PNG filter {filter_type}: {path}")
        prev = row

        samples = _unpack_samples(row, width, bit_depth, channels)
        for x in range(width):
            s = samples[x * channels : (x + 1) * channels]
            i = (y * width + x) * 4
            if color_type == 0:
                g = int(s[0] * gray_scale)
                r = blue = g
                alpha = 0 if trns_gray is not None and s[0] == trns_gray else 255
            elif color_type == 2:
                r, g, blue = s[0], s[1], s[2]
                alpha = 0 if trns_rgb is not None and tuple(s[:3]) == trns_rgb else 255
            elif color_type == 3:
                idx = s[0]
                if idx * 3 + 2 >= len(palette):
                    raise ValueError(f"Palette index out of range: {path}")
                r, g, blue = palette[idx * 3 : idx * 3 + 3]
                alpha = transparent[idx] if idx < len(transparent) else 255
            elif color_type == 4:
                r = g = blue = s[0]
                alpha = s[1]
            else:  # colour type 6, RGBA
                r, g, blue, alpha = s[0], s[1], s[2], s[3]
            out[i] = r
            out[i + 1] = g
            out[i + 2] = blue
            out[i + 3] = alpha
    return width, height, out


def resize_rgba(pixels, src_w, src_h, dst_w, dst_h):
    """Bilinear RGBA resize from the master icon to a launcher density."""
    if (src_w, src_h) == (dst_w, dst_h):
        return bytearray(pixels)
    out = bytearray(dst_w * dst_h * 4)
    for y in range(dst_h):
        fy = (y + 0.5) * src_h / dst_h - 0.5
        y0 = max(0, min(src_h - 1, math.floor(fy)))
        y1 = max(0, min(src_h - 1, y0 + 1))
        wy = min(1.0, max(0.0, fy - y0))
        for x in range(dst_w):
            fx = (x + 0.5) * src_w / dst_w - 0.5
            x0 = max(0, min(src_w - 1, math.floor(fx)))
            x1 = max(0, min(src_w - 1, x0 + 1))
            wx = min(1.0, max(0.0, fx - x0))
            o = (y * dst_w + x) * 4
            for c in range(4):
                p00 = pixels[(y0 * src_w + x0) * 4 + c]
                p01 = pixels[(y0 * src_w + x1) * 4 + c]
                p10 = pixels[(y1 * src_w + x0) * 4 + c]
                p11 = pixels[(y1 * src_w + x1) * 4 + c]
                top = p00 + (p01 - p00) * wx
                bottom = p10 + (p11 - p10) * wx
                out[o + c] = int(round(top + (bottom - top) * wy))
    return out


def apply_round_mask(pixels, size):
    """Circular alpha mask with a short antialiased edge for the round icon."""
    out = bytearray(pixels)
    cx = cy = (size - 1) / 2.0
    radius = size / 2.0
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / radius
            i = (y * size + x) * 4
            if d >= 1.0:
                out[i + 3] = 0
            elif d > 0.95:
                out[i + 3] = int(out[i + 3] * (1.0 - d) / 0.05)
    return out


def main():
    if not SOURCE_ICON.is_file():
        write_png(SOURCE_ICON, 512, draw_icon(512))
        print(f"Created {SOURCE_ICON.relative_to(ROOT)} from the fallback drawing.")

    src_w, src_h, src_px = read_png(SOURCE_ICON)
    densities = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for name, size in densities.items():
        res = ROOT / "android" / "app" / "src" / "main" / "res" / f"mipmap-{name}"
        scaled = resize_rgba(src_px, src_w, src_h, size, size)
        write_png(res / "ic_launcher.png", size, scaled)
        write_png(res / "ic_launcher_round.png", size, apply_round_mask(scaled, size))

    print(f"ARIFA launcher icons generated from {SOURCE_ICON.relative_to(ROOT)}.")


if __name__ == "__main__":
    main()
