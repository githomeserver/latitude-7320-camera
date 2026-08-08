#!/usr/bin/env python3
# Render a captured frame through candidate colour correction matrices, so you
# can compare them side by side instead of restarting the relay for each one.
#
# WHY THIS IS FAITHFUL
#
# The soft ISP's CPU debayer computes, per pixel:
#
#     out = gammaLut[ CCM * (gains * (raw - blacklevel)) ]
#
# (debayer_cpu.cpp STORE_PIXEL: the CCM columns are linear, GAMMA() is applied
# to their sum). gamma is a pure power curve, kDefaultGamma = 2.2, and
# kDefaultContrast = 1.0 so there is no extra tone curve to undo.
#
# With no CCM in the tuning file the matrix is identity, so a captured frame is
# exactly (gains * (raw - blacklevel)) ^ (1/2.2). Raising it to 2.2 recovers the
# linear signal the CCM would have seen, and re-applying 1/2.2 afterwards
# reproduces what the pipeline would have emitted. No approximation.
#
# This is only true for frames captured with NO ccm already in the tuning file.
# Once you install one, re-capture before tuning further, or you compound them.
#
# Usage:
#   ./try-ccm.py frame.png out.png                    default candidate set
#   ./try-ccm.py frame.png out.png sat=2.0 sat=2.5    named presets
#   ./try-ccm.py frame.png out.png 1.7,-0.6,-0.1,...  explicit 9-number matrix
#
# Presets:
#   identity            no change, for reference
#   sat=N               saturation N, preserving neutrals (rows sum to 1)
#   sat=N,blue=B        as above, then scale the blue output row by B

import sys
import os
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)
from PIL import Image, ImageDraw

GAMMA = 2.2
# Rec.601 luma weights, matching how saturation is conventionally defined.
LUMA = (0.299, 0.587, 0.114)
PREVIEW_W = 440


def saturation_matrix(s, blue=1.0):
    """Rows sum to 1, so neutrals stay neutral and white balance is preserved."""
    wr, wg, wb = LUMA
    m = [
        [(1 - s) * wr + s, (1 - s) * wg, (1 - s) * wb],
        [(1 - s) * wr, (1 - s) * wg + s, (1 - s) * wb],
        [(1 - s) * wr, (1 - s) * wg, (1 - s) * wb + s],
    ]
    # Trimming the blue row deliberately breaks the sum-to-1 property: it is a
    # white balance change, not a saturation one. Kept separate for that reason.
    if blue != 1.0:
        m[2] = [v * blue for v in m[2]]
    return m


def hue_matrix(deg):
    """Rotate hue about the (1,1,1) axis. Neutrals are on that axis, so they are
    fixed exactly - a white wall stays white however far this is turned."""
    import math
    th = math.radians(deg)
    c, s = math.cos(th), math.sin(th)
    k = 1.0 / math.sqrt(3.0)
    # Rodrigues: I*c + sin*[u]x + (1-c)*u u^T, with u = (1,1,1)/sqrt(3)
    o = (1.0 - c) / 3.0
    return [
        [c + o,           o - k * s,   o + k * s],
        [o + k * s,       c + o,       o - k * s],
        [o - k * s,       o + k * s,   c + o],
    ]


def matmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)]
            for i in range(3)]


def parse(spec):
    if spec == "identity":
        return spec, [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

    if spec.startswith(("sat=", "hue=", "wb=")):
        parts = dict(p.split("=") for p in spec.split(","))
        s = float(parts.get("sat", 1.0))
        b = float(parts.get("blue", 1.0))
        h = float(parts.get("hue", 0.0))
        m = saturation_matrix(s, b)
        # Hue first, then saturation: rotating an already-stretched colour can
        # push it outside gamut in a direction the stretch then exaggerates.
        if h:
            m = matmul(m, hue_matrix(h))
        # wb=r:g:b is a diagonal white balance applied BEFORE the above, so the
        # saturation stretch acts on already-neutral data. Getting this order
        # backwards stretches the cast instead of the colour.
        w = parts.get("wb")
        if w:
            wr, wg, wb_ = (float(x) for x in w.split(":"))
            m = matmul(m, [[wr, 0, 0], [0, wg, 0], [0, 0, wb_]])
        return spec, m

    nums = [float(x) for x in spec.replace(" ", "").split(",")]
    if len(nums) != 9:
        sys.exit(f"matrix '{spec}' needs 9 numbers, got {len(nums)}")
    return spec, [nums[0:3], nums[3:6], nums[6:9]]


def apply_ccm(img, m):
    """img is 8-bit sRGB-ish; returns a new image with m applied in linear light."""
    w, h = img.size
    px = list(img.getdata())

    # Linearise 0..255 once - only 256 possible inputs, so a LUT is exact.
    lin = [(i / 255.0) ** GAMMA for i in range(256)]

    # The re-encode is computed directly rather than through a LUT. A linear
    # LUT cannot resolve the shadows: (2/255)^2.2 is 2.3e-5, finer than one
    # step in 16384, so dark pixels collapsed together and the identity
    # round-trip drifted 2/255 - which while tuning would have been
    # indistinguishable from a real effect. Previews are small; pow() is cheap.
    inv = 1.0 / GAMMA

    (a, b, c), (d, e, f), (g, hh, i) = m
    out = []
    for r, gr, bl in px:
        rl, gl, bll = lin[r], lin[gr], lin[bl]
        nr = a * rl + b * gl + c * bll
        ng = d * rl + e * gl + f * bll
        nb = g * rl + hh * gl + i * bll
        # Clamp in linear, as the pipeline does before its LUT lookup.
        nr = 0.0 if nr < 0 else (1.0 if nr > 1 else nr)
        ng = 0.0 if ng < 0 else (1.0 if ng > 1 else ng)
        nb = 0.0 if nb < 0 else (1.0 if nb > 1 else nb)
        out.append((round(nr ** inv * 255),
                    round(ng ** inv * 255),
                    round(nb ** inv * 255)))

    res = Image.new("RGB", (w, h))
    res.putdata(out)
    return res


def main():
    # --matrix prints the 9 coefficients for a spec, so install-ccm.sh can
    # generate a tuning file without duplicating the maths.
    if len(sys.argv) == 3 and sys.argv[1] == "--matrix":
        _, m = parse(sys.argv[2])
        print(", ".join(f"{v:.4f}" for row in m for v in row))
        return

    if len(sys.argv) < 3:
        sys.exit(__doc__ or "usage: try-ccm.py frame.png out.png [spec ...]")

    src, dst = sys.argv[1], sys.argv[2]
    specs = sys.argv[3:] or [
        "identity", "sat=1.5", "sat=2.0",
        "sat=2.5", "sat=2.0,blue=0.92", "sat=2.5,blue=0.92",
    ]

    if not os.path.exists(src):
        sys.exit(f"no such frame: {src}")

    img = Image.open(src).convert("RGB")
    scale = PREVIEW_W / img.width
    img = img.resize((PREVIEW_W, round(img.height * scale)), Image.LANCZOS)
    w, h = img.size

    label_h = 18
    cols = 3 if len(specs) > 2 else len(specs)
    rows = (len(specs) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * w, rows * (h + label_h)), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)

    for n, spec in enumerate(specs):
        name, m = parse(spec)
        print(f"  rendering {name}", flush=True)
        tile = apply_ccm(img, m)
        x = (n % cols) * w
        y = (n // cols) * (h + label_h)
        sheet.paste(tile, (x, y + label_h))
        draw.text((x + 5, y + 4), f"{n + 1}. {name}", fill=(255, 255, 255))

    sheet.save(dst)
    print(f"\nwrote {dst}  ({cols}x{rows} variants)")


if __name__ == "__main__":
    main()
