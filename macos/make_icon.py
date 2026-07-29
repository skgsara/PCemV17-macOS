#!/usr/bin/env python3
"""make_icon.py — generate PCemMac's AppIcon.icns with zero dependencies.

Draws a chunky retro all-in-one PC (beige monitor, dark bezel, terminal-green
screen with a >_ prompt) on the macOS squircle, and emits a full
AppIcon.iconset (16..512 pt @1x/@2x) + AppIcon.icns via iconutil.

Everything is drawn on a 1024x1024 RGBA canvas pixel-by-pixel and box-
downscaled for the smaller sizes, so small icons stay readable (they get
thicker strokes in proportion by design — the art uses few, large shapes).

Usage:  python3 macos/make_icon.py        # writes macos/AppIcon.iconset + .icns
Re-run only when you want to change the art; the .icns is committed.
"""

import os
import struct
import subprocess
import sys
import zlib

SIZE = 1024  # master canvas

# ---------------------------------------------------------------- palette
SQUIRCLE_TOP    = (58, 64, 78)     # dark blue-gray backdrop, subtle vertical
SQUIRCLE_BOTTOM = (30, 33, 42)     # gradient
BEIGE_LIGHT     = (232, 224, 205)  # monitor plastic, lit from above
BEIGE           = (214, 205, 184)
BEIGE_DARK      = (188, 178, 156)
BEZEL_DARK      = (64, 60, 54)     # screen bezel
SCREEN_DARK     = (16, 26, 20)     # CRT glass, phosphor green glow
GREEN           = (88, 230, 120)   # terminal green
GREEN_DIM       = (54, 150, 80)


def clamp(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


class Canvas:
    def __init__(self, size):
        self.size = size
        self.px = bytearray(size * size * 4)  # RGBA, row-major

    def set(self, x, y, rgba):
        if 0 <= x < self.size and 0 <= y < self.size:
            i = (y * self.size + x) * 4
            self.px[i:i + 4] = bytes(rgba)

    def blend(self, x, y, rgb, a):
        """Alpha-blend rgb over the pixel with coverage a in 0..1."""
        if not (0 <= x < self.size and 0 <= y < self.size):
            return
        i = (y * self.size + x) * 4
        ia = 1.0 - a
        self.px[i]     = clamp(rgb[0] * a + self.px[i] * ia)
        self.px[i + 1] = clamp(rgb[1] * a + self.px[i + 1] * ia)
        self.px[i + 2] = clamp(rgb[2] * a + self.px[i + 2] * ia)
        self.px[i + 3] = clamp(255 * a + self.px[i + 3] * ia)


def rounded_rect_cov(x, y, x0, y0, x1, y1, r):
    """Coverage (0..1) of pixel (x,y) by a rounded rect [x0,y0)-[x1,y1),
    corner radius r. Simple 1px anti-alias band via distance to edge."""
    # distance outside the rounded rect (negative inside)
    cx = min(max(x + 0.5, x0 + r), x1 - r)
    cy = min(max(y + 0.5, y0 + r), y1 - r)
    dx = (x + 0.5) - cx
    dy = (y + 0.5) - cy
    # outside the corner circle?
    d_corner = (dx * dx + dy * dy) ** 0.5 - r
    # outside the straight edges?
    d_edge = max(x0 - (x + 0.5), (x + 0.5) - x1,
                 y0 - (y + 0.5), (y + 0.5) - y1)
    in_core_x = x0 + r <= x + 0.5 < x1 - r
    in_core_y = y0 + r <= y + 0.5 < y1 - r
    d = d_edge if (in_core_x or in_core_y) else d_corner
    if d <= -0.5:
        return 1.0
    if d >= 0.5:
        return 0.0
    return 0.5 - d


def fill_rounded(cv, x0, y0, x1, y1, r, rgb):
    for y in range(int(y0) - 1, int(y1) + 2):
        for x in range(int(x0) - 1, int(x1) + 2):
            a = rounded_rect_cov(x, y, x0, y0, x1, y1, r)
            if a > 0:
                cv.blend(x, y, rgb, a)


def fill_rounded_vgrad(cv, x0, y0, x1, y1, r, rgb_top, rgb_bottom):
    span = max(1.0, (y1 - y0))
    for y in range(int(y0) - 1, int(y1) + 2):
        t = min(1.0, max(0.0, (y + 0.5 - y0) / span))
        rgb = tuple(clamp(rgb_top[i] * (1 - t) + rgb_bottom[i] * t)
                    for i in range(3))
        for x in range(int(x0) - 1, int(x1) + 2):
            a = rounded_rect_cov(x, y, x0, y0, x1, y1, r)
            if a > 0:
                cv.blend(x, y, rgb, a)


def fill_rect(cv, x0, y0, x1, y1, rgb):
    for y in range(int(y0), int(y1)):
        for x in range(int(x0), int(x1)):
            cv.set(x, y, (*rgb, 255))


def draw_icon(cv):
    s = cv.size  # 1024

    # -- squircle backdrop (macOS icon silhouette, r ≈ 22.37%) ------------
    m = s * 0.02                     # tiny margin; icon should fill the tile
    fill_rounded_vgrad(cv, m, m, s - m, s - m, s * 0.2237,
                       SQUIRCLE_TOP, SQUIRCLE_BOTTOM)

    # -- monitor body (putty/beige, slight top light) ---------------------
    bx0, by0 = s * 0.17, s * 0.20
    bx1, by1 = s * 0.83, s * 0.74
    fill_rounded_vgrad(cv, bx0, by0, bx1, by1, s * 0.045,
                       BEIGE_LIGHT, BEIGE)

    # lower shadow lip of the case
    fill_rounded(cv, bx0, by1 - s * 0.045, bx1, by1, s * 0.03, BEIGE_DARK)

    # -- screen bezel ------------------------------------------------------
    sx0, sy0 = s * 0.24, s * 0.27
    sx1, sy1 = s * 0.76, s * 0.63
    fill_rounded(cv, sx0, sy0, sx1, sy1, s * 0.02, BEZEL_DARK)

    # -- CRT glass ----------------------------------------------------------
    gx0, gy0 = sx0 + s * 0.022, sy0 + s * 0.022
    gx1, gy1 = sx1 - s * 0.022, sy1 - s * 0.022
    fill_rounded_vgrad(cv, gx0, gy0, gx1, gy1, s * 0.012,
                       SCREEN_DARK, (10, 16, 13))

    # -- terminal text: ">_" prompt in phosphor green -----------------------
    tx, ty = gx0 + s * 0.045, gy0 + s * 0.055
    t = s * 0.020                    # stroke thickness
    # '>' chevron
    chw, chh = s * 0.085, s * 0.11   # chevron width/height
    for i in range(int(chw)):
        prog = i / chw
        y_top = ty + prog * chh * 0.5
        y_bot = ty + chh - prog * chh * 0.5
        fill_rect(cv, tx + i, y_top, tx + i + 1, y_top + t, GREEN)
        fill_rect(cv, tx + i, y_bot, tx + i + 1, y_bot + t, GREEN)
    # '_' cursor (blinking-block look), to the right of the chevron
    ux0 = tx + chw + s * 0.035
    fill_rect(cv, ux0, ty + chh - t, ux0 + s * 0.075, ty + chh, GREEN)

    # faint scanlines for CRT flavour (subtle, every 4 px on the glass)
    for y in range(int(gy0), int(gy1), 8):
        for x in range(int(gx0), int(gx1)):
            i = (y * cv.size + x) * 4
            cv.px[i]     = clamp(cv.px[i] * 0.92)
            cv.px[i + 1] = clamp(cv.px[i + 1] * 0.92)
            cv.px[i + 2] = clamp(cv.px[i + 2] * 0.92)

    # -- case details: floppy slot + power LED ------------------------------
    cy = by1 - s * 0.085
    fill_rect(cv, s * 0.60, cy, s * 0.76, cy + s * 0.012, BEZEL_DARK)
    ledx = s * 0.24
    fill_rounded(cv, ledx, cy - s * 0.002, ledx + s * 0.016, cy + s * 0.014,
                 s * 0.006, GREEN_DIM)

    # -- stand/foot ----------------------------------------------------------
    fill_rounded(cv, s * 0.38, by1, s * 0.62, s * 0.80, s * 0.02, BEIGE_DARK)


# ------------------------------------------------------------ PNG writing
def png_bytes(rgb, w, h):
    """rgb: bytes of length w*h*4 (RGBA). Minimal PNG encoder."""
    raw = b"".join(b"\x00" + rgb[y * w * 4:(y + 1) * w * 4]
                   for y in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def downscale(px, src, dst):
    """Box-average downscale RGBA bytearray from src x src to dst x dst."""
    out = bytearray(dst * dst * 4)
    f = src / dst
    for y in range(dst):
        for x in range(dst):
            r = g = b = a = n = 0
            y0, y1 = int(y * f), max(int(y * f) + 1, int((y + 1) * f))
            x0, x1 = int(x * f), max(int(x * f) + 1, int((x + 1) * f))
            for sy in range(y0, min(y1, src)):
                for sx in range(x0, min(x1, src)):
                    i = (sy * src + sx) * 4
                    r += px[i]; g += px[i + 1]; b += px[i + 2]; a += px[i + 3]
                    n += 1
            o = (y * dst + x) * 4
            out[o:o + 4] = bytes((r // n, g // n, b // n, a // n))
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    iconset = os.path.join(here, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    cv = Canvas(SIZE)
    draw_icon(cv)

    # iconutil naming: icon_{16,32,128,256,512}x.png + @2x variants
    specs = [(16, 16), (16, 32), (32, 32), (32, 64), (128, 128),
             (128, 256), (256, 256), (256, 512), (512, 512), (512, 1024)]
    for base, pix in specs:
        suffix = "" if pix == base else "@2x"
        name = f"icon_{base}x{base}{suffix}.png"
        data = cv.px if pix == SIZE else downscale(cv.px, SIZE, pix)
        with open(os.path.join(iconset, name), "wb") as f:
            f.write(png_bytes(bytes(data), pix, pix))
        print("wrote", name)

    icns = os.path.join(here, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("wrote", icns)


if __name__ == "__main__":
    sys.exit(main())
