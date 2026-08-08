#!/usr/bin/env python3
"""Generate a colour target to display on a screen for CCM fitting.

Twenty-four patches using the standard ColorChecker sRGB values - not because
we are reproducing a ColorChecker (we are not; that is a reflective chart under
an illuminant, this is an emissive display) but because they are a well spread
set of colours whose intended sRGB values are known. For fitting a
camera-RGB -> sRGB matrix, knowing the target values is what matters.

The grid fills the image edge to edge with no border, so "fill the camera frame
with the grid" is an unambiguous instruction and the sampler can assume the
patches divide the frame evenly.

Usage: make-ccm-target.py [out.png] [width] [height]
"""

import sys

from PIL import Image, ImageDraw

# Standard 24-patch ColorChecker, sRGB 8-bit, reading order.
PATCHES = [
    ("dark skin",     (115,  82,  68)), ("light skin",   (194, 150, 130)),
    ("blue sky",      ( 98, 122, 157)), ("foliage",      ( 87, 108,  67)),
    ("blue flower",   (133, 128, 177)), ("bluish green", (103, 189, 170)),
    ("orange",        (214, 126,  44)), ("purplish blue",( 80,  91, 166)),
    ("moderate red",  (193,  90,  99)), ("purple",       ( 94,  60, 108)),
    ("yellow green",  (157, 188,  64)), ("orange yellow",(224, 163,  46)),
    ("blue",          ( 56,  61, 150)), ("green",        ( 70, 148,  73)),
    ("red",           (175,  54,  60)), ("yellow",       (231, 199,  31)),
    ("magenta",       (187,  86, 149)), ("cyan",         (  8, 133, 161)),
    ("white",         (243, 243, 242)), ("neutral 8",    (200, 200, 200)),
    ("neutral 6.5",   (160, 160, 160)), ("neutral 5",    (122, 122, 121)),
    ("neutral 3.5",   ( 85,  85,  85)), ("black",        ( 52,  52,  52)),
]

COLS, ROWS = 6, 4


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "ccm-target.png"
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 1920
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 1280

    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)

    for i, (_name, rgb) in enumerate(PATCHES):
        r, c = divmod(i, COLS)
        x0 = round(c * w / COLS)
        x1 = round((c + 1) * w / COLS)
        y0 = round(r * h / ROWS)
        y1 = round((r + 1) * h / ROWS)
        d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=rgb)

    img.save(out)
    print(f"wrote {out}  {w}x{h}  {COLS}x{ROWS} patches")
    print()
    print("Display this fullscreen on the tablet, at a brightness that is bright")
    print("but not blinding, and fill the camera frame with it as squarely as you")
    print("can. Edge to edge - no border, no desktop visible.")


if __name__ == "__main__":
    main()
