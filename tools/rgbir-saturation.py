#!/usr/bin/env python3
"""Sweep saturation and IR subtraction on a saved RGB-IR raw frame.

Sahan confirmed on live captures (2026-08-15) that phase A is correct - red and
blue are inverted in the 2x2 reading and in both phase B variants, while green
is identical across all six, which is the control that had to hold. Of the
phase A variants he ranked IR-2.0 best for colour but noisiest, then IR-1.0,
then no subtraction. That ordering is the trade this script explores.

WHY IR SUBTRACTION COSTS NOISE. Subtracting the IR plane removes the infrared
contamination from every colour channel, but it also ADDS the IR channel's own
noise to each of them - and IR is the weakest channel by far (about 9 counts
against green's 98 on the last frame). So the noise penalty scales with the
correction. Saturation boost is the alternative: it amplifies the chroma that
is already there without pulling in another noisy channel, at the cost of
amplifying whatever chroma error remains.

Saturation is applied in LINEAR light, after white balance and before gamma.
Applying it after gamma encoding distorts hue, and this project has already
been caught once comparing gamma-encoded values as if they were linear.

    ./rgbir-saturation.py [raw]      writes /tmp/rgbir-sat-N.png and a sheet
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "rgbir", os.path.join(HERE, "rgbir-offline.py"))
rgbir = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rgbir)
from PIL import Image, ImageDraw

# Rec.709 luma, the same weighting the rest of the project uses for linear work.
LR, LG, LB = 0.2126, 0.7152, 0.0722


def encode_sat(R, G, B, w, h, ir=None, ir_sub=0.0, sat=1.0):
    """rgbir-offline.encode with a linear-light saturation stage added."""
    n = len(R)
    if ir_sub and ir:
        R = [r - ir_sub * v for r, v in zip(R, ir)]
        G = [g - ir_sub * v for g, v in zip(G, ir)]
        B = [b - ir_sub * v for b, v in zip(B, ir)]
    mr = sum(max(v, 0.0) for v in R) / n
    mg = sum(max(v, 0.0) for v in G) / n
    mb = sum(max(v, 0.0) for v in B) / n
    gr, gb = mg / max(mr, 1e-6), mg / max(mb, 1e-6)
    ref = max(sorted(max(v, 0.0) for v in G)[int(n * 0.99)], 1e-6)
    out = bytearray(n * 3)
    inv = 1.0 / 2.2
    for k in range(n):
        r = max(R[k], 0.0) * gr / ref
        g = max(G[k], 0.0) / ref
        b = max(B[k], 0.0) * gb / ref
        if sat != 1.0:
            y = LR * r + LG * g + LB * b
            r = y + (r - y) * sat
            g = y + (g - y) * sat
            b = y + (b - y) * sat
        for c, v in enumerate((r, g, b)):
            out[k * 3 + c] = min(255, round(min(max(v, 0.0), 1.0) ** inv * 255))
    return Image.frombytes("RGB", (w, h), bytes(out))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/scene-raw.bin"
    if not os.path.exists(path):
        sys.exit(f"no raw at {path}")
    data, w, h, stride, black = rgbir.load(path)
    p16, W, H = rgbir.planes(data, w, h, stride, black)
    idx = {c: [i * 4 + j for i in range(4) for j in range(4)
               if rgbir.PATTERN[i][j] == c] for c in "GIRB"}
    G8 = rgbir.combine(p16, idx["G"])
    IR = rgbir.combine(p16, idx["I"])
    Ra = rgbir.combine(p16, idx["R"])
    Ba = rgbir.combine(p16, idx["B"])

    # All phase A - that is settled. Only IR subtraction and saturation vary.
    variants = [
        ("IR-2.0 sat1.0  (current best)", 2.0, 1.0),
        ("IR-2.0 sat1.4", 2.0, 1.4),
        ("IR-2.0 sat1.8", 2.0, 1.8),
        ("IR-1.0 sat1.6  (less grain)", 1.0, 1.6),
        ("IR-1.0 sat2.0", 1.0, 2.0),
        ("IR-0   sat2.0  (cleanest)", 0.0, 2.0),
    ]
    cols, lab = 3, 16
    rows = (len(variants) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * W, rows * (H + lab)), (24, 24, 24))
    d = ImageDraw.Draw(sheet)
    for k, (nm, sub, sat) in enumerate(variants):
        im = encode_sat(Ra, G8, Ba, W, H, IR, sub, sat)
        x, y = (k % cols) * W, (k // cols) * (H + lab)
        sheet.paste(im, (x, y + lab))
        d.text((x + 4, y + 3), f"{k+1}. {nm}", fill=(255, 255, 255))
        im.save(f"/tmp/rgbir-sat-{k+1}.png")
        print(f"  {k+1}. {nm}")
    sheet.save("/tmp/rgbir-sat-sheet.png")
    print("\nwrote /tmp/rgbir-sat-sheet.png and /tmp/rgbir-sat-N.png")
    print("Noise rises with IR subtraction, not with saturation - so if grain is")
    print("the limit, prefer a lower IR-sub with a higher sat.")


if __name__ == "__main__":
    main()
