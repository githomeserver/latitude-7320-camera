#!/usr/bin/env python3
"""Explore mosaic interpretations of a saved raw frame. No hardware needed.

check-rgbir proved there is 4x4 structure but did NOT pin the phase: shifting
the pattern two columns swaps R and B while leaving every group just as
self-consistent, so both alignments pass that test. This renders the
candidates from one raw capture so they can be compared directly.

    ./rgbir-offline.py [/tmp/rgbir-raw.bin]

Writes /tmp/rgbir-variants.png and prints channel statistics, including the
most chromatic cells in the frame - which is the real question: does colour
information exist in this data at all, or does the mosaic reading only change
how it is labelled?
"""

import os
import sys

from PIL import Image

PATTERN = [
    ["G", "I", "G", "I"],
    ["R", "G", "B", "G"],
    ["G", "I", "G", "I"],
    ["B", "G", "R", "G"],
]


def load(path):
    meta = open(path + ".txt").read().split("\n")
    w, h, stride, fourcc = meta[0].split()
    w, h, stride = int(w), int(h), int(stride)
    black = [int(v) for v in meta[1].split()[1:]]
    data = open(path, "rb").read()
    assert len(data) >= stride * h, "raw shorter than its own metadata"
    return data, w, h, stride, black


def planes(data, w, h, stride, black):
    """One value per 4x4 cell for each of the 16 positions."""
    W, H = w // 4, h // 4
    out = [[0.0] * (W * H) for _ in range(16)]
    for cy in range(H):
        rows = [(cy * 4 + dy) * stride for dy in range(4)]
        base_o = cy * W
        for cx in range(W):
            x2 = cx * 8
            k = 0
            for r in rows:
                o = r + x2
                for _ in range(4):
                    out[k][base_o + cx] = (data[o] | (data[o + 1] << 8)) - black[k]
                    o += 2
                    k += 1
    return out, W, H


def combine(p16, idx):
    n = len(p16[0])
    return [sum(p16[i][k] for i in idx) / len(idx) for k in range(n)]


def encode(R, G, B, w, h, ir=None, ir_sub=0.0):
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
        for c, (v, gn) in enumerate(((R[k], gr), (G[k], 1.0), (B[k], gb))):
            x = max(v, 0.0) * gn / ref
            out[k * 3 + c] = min(255, round(min(x, 1.0) ** inv * 255))
    return Image.frombytes("RGB", (w, h), bytes(out))


def chroma_report(name, R, G, B):
    n = len(R)
    sats = []
    for k in range(n):
        mx = max(R[k], G[k], B[k])
        mn = min(R[k], G[k], B[k])
        sats.append(0.0 if mx <= 0 else (mx - mn) / mx)
    order = sorted(range(n), key=lambda k: sats[k], reverse=True)
    top = order[:max(1, n // 100)]
    print(f"  {name:26} mean chroma {sum(sats)/n*100:5.1f}%   "
          f"top-1% {sum(sats[k] for k in top)/len(top)*100:5.1f}%")
    return sats


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rgbir-raw.bin"
    if not os.path.exists(path):
        sys.exit(f"no raw at {path} - run rgbir-proof.sh first")
    data, w, h, stride, black = load(path)
    print(f"raw {w}x{h} stride {stride}, black {black[0]}")
    print("parsing 4x4 cells...")
    p16, W, H = planes(data, w, h, stride, black)

    idx = {c: [i * 4 + j for i in range(4) for j in range(4)
               if PATTERN[i][j] == c] for c in "GIRB"}
    G8 = combine(p16, idx["G"])
    IR = combine(p16, idx["I"])
    Ra = combine(p16, idx["R"])          # phase as declared
    Ba = combine(p16, idx["B"])
    # Bayer-2x2 reading, i.e. what ships today.
    bG = combine(p16, [i * 4 + j for i in range(4) for j in range(4)
                       if (i + j) % 2 == 0])
    bB = combine(p16, [i * 4 + j for i in range(4) for j in range(4)
                       if i % 2 == 0 and j % 2 == 1])
    bR = combine(p16, [i * 4 + j for i in range(4) for j in range(4)
                       if i % 2 == 1 and j % 2 == 0])

    def mean(v):
        return sum(v) / len(v)
    print(f"\nchannel means (10-bit, black subtracted)")
    print(f"  G {mean(G8):7.1f}   IR {mean(IR):7.1f}   "
          f"R {mean(Ra):7.1f}   B {mean(Ba):7.1f}")
    print(f"  as 2x2:  R {mean(bR):7.1f}  G {mean(bG):7.1f}  B {mean(bB):7.1f}"
          f"   (B/G {mean(bB)/mean(bG):.3f} - this is why blue needed ~8x)")
    print(f"  as 4x4:  R {mean(Ra):7.1f}  G {mean(G8):7.1f}  B {mean(Ba):7.1f}"
          f"   (B/G {mean(Ba)/mean(G8):.3f})")

    print("\nchroma - does colour information exist in the data?")
    chroma_report("2x2 GBRG (ships today)", bR, bG, bB)
    chroma_report("RGB-IR phase A", Ra, G8, Ba)
    chroma_report("RGB-IR phase B (R/B swap)", Ba, G8, Ra)
    chroma_report("RGB-IR A, IR sub 1.0",
                  [r - i for r, i in zip(Ra, IR)],
                  [g - i for g, i in zip(G8, IR)],
                  [b - i for b, i in zip(Ba, IR)])

    variants = [
        ("2x2 GBRG (now)", bR, bG, bB, None, 0.0),
        ("RGB-IR phase A", Ra, G8, Ba, None, 0.0),
        ("RGB-IR phase B", Ba, G8, Ra, None, 0.0),
        ("RGB-IR A, IR-1.0", Ra, G8, Ba, IR, 1.0),
        ("RGB-IR A, IR-2.0", Ra, G8, Ba, IR, 2.0),
        ("RGB-IR B, IR-1.0", Ba, G8, Ra, IR, 1.0),
    ]
    from PIL import ImageDraw
    cols, lab = 3, 16
    rows = (len(variants) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * W, rows * (H + lab)), (24, 24, 24))
    d = ImageDraw.Draw(sheet)
    for k, (nm, R, G, B, ir, s) in enumerate(variants):
        im = encode(R, G, B, W, H, ir, s)
        x, y = (k % cols) * W, (k // cols) * (H + lab)
        sheet.paste(im, (x, y + lab))
        d.text((x + 4, y + 3), f"{k+1}. {nm}", fill=(255, 255, 255))
        im.save(f"/tmp/rgbir-v{k+1}.png")
    sheet.save("/tmp/rgbir-variants.png")
    print("\nwrote /tmp/rgbir-variants.png")


if __name__ == "__main__":
    main()
