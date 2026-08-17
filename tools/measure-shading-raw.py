#!/usr/bin/env python3
"""Measure per-channel lens shading from RAW mosaic frames.

Why not from the processed image: the CCM mixes channels. Ours has a red row of
1.81R - 0.345G - 0.465B, so the red you measure at the corner of a processed
frame is a blend of all three sensor channels. Measured that way this camera
appeared to need LESS corner gain on red than green, while Intel's tables say
more - a disagreement in direction, produced entirely by the matrix.

Reading the mosaic directly avoids the debayer, the CCM, the gamma curve and the
AWB gains. Each pixel is one sensor channel at one position, which is exactly
what a shading table describes.

    ./measure-shading-raw.py <dir with rawcam0-stream0-*.bin> [-o map.bin]
"""

import argparse
import glob
import os
import struct
import sys

W, H = 2592, 1944
GRID_W, GRID_H = 63, 47
ONE = 2048
BLACK = 64                      # sensor pedestal at 10 bits

# G I G I / R G B G / G I G I / B G R G, Intel's GIGI_RGBG_GIGI_BGRG.
PATTERN = [
    0, 1, 0, 1,
    2, 0, 3, 0,
    0, 1, 0, 1,
    3, 0, 2, 0,
]
NAMES = {0: "G", 1: "IR", 2: "R", 3: "B"}


def accumulate(paths):
    """Sum each channel per grid cell across frames. Averaging frames first
    keeps sensor noise out of the gain map, which is otherwise baked in."""
    sums = [[0.0] * (GRID_W * GRID_H) for _ in range(4)]
    counts = [[0] * (GRID_W * GRID_H) for _ in range(4)]
    for p in paths:
        raw = open(p, "rb").read()
        if len(raw) != W * H * 2:
            print(f"  skipping {os.path.basename(p)}: {len(raw)} bytes", file=sys.stderr)
            continue
        mv = memoryview(raw).cast("H")
        # Every row and column. Green sits on even parity in this mosaic, so
        # stride-2 in BOTH axes lands exclusively on green and reads zero for
        # R, B and IR - which is exactly what the first version of this did.
        for y in range(H):
            gy = y * GRID_H // H
            rowbase = y * W
            prow = (y % 4) * 4
            for x in range(W):
                ch = PATTERN[prow + (x % 4)]
                v = mv[rowbase + x] - BLACK
                if v < 0:
                    v = 0
                idx = gy * GRID_W + (x * GRID_W // W)
                sums[ch][idx] += v
                counts[ch][idx] += 1
    return sums, counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("-o", "--output")
    ap.add_argument("--compare", help="Intel map to compare against")
    args = ap.parse_args()

    paths = sorted(glob.glob(os.path.join(args.dir, "rawcam0-stream0-*.bin")))
    if not paths:
        raise SystemExit(f"no raw frames in {args.dir}")
    print(f"  averaging {len(paths)} raw frames")
    sums, counts = accumulate(paths)

    means = []
    for ch in range(4):
        means.append([s / c if c else 0.0 for s, c in zip(sums[ch], counts[ch])])

    # Flat-field sanity, on green.
    g = means[0]
    ctr = g[(GRID_H // 2) * GRID_W + GRID_W // 2]
    gmax = max(g)
    if ctr <= 0:
        raise SystemExit("green centre is zero - bad capture")
    if ctr < gmax * 0.9:
        raise SystemExit("brightest area is not the centre - not a flat field")
    sat = sum(1 for v in g if v > 900)
    if sat:
        raise SystemExit(f"{sat} cells near saturation - too bright, reshoot darker")
    print(f"  green centre {ctr:.0f} counts, max {gmax:.0f}, no clipping")

    def corner(v):
        return (v[2 * GRID_W + 2] + v[2 * GRID_W + GRID_W - 3] +
                v[(GRID_H - 3) * GRID_W + 2] + v[(GRID_H - 3) * GRID_W + GRID_W - 3]) / 4

    print("\n  channel   centre   corner   needs")
    need = {}
    for ch in range(4):
        c = means[ch][(GRID_H // 2) * GRID_W + GRID_W // 2]
        co = corner(means[ch])
        need[ch] = c / co if co > 0 else 1.0
        print(f"    {NAMES[ch]:<3}    {c:8.1f} {co:8.1f}   {need[ch]:5.2f}x")
    print(f"\n  ratios to green:  R/G {need[2]/need[0]:.3f}   B/G {need[3]/need[0]:.3f}"
          f"   IR/G {need[1]/need[0]:.3f}")

    if args.compare:
        d = open(args.compare, "rb").read()
        mw, mh, mone, _ = struct.unpack_from("<4H", d, 0)
        n = mw * mh
        print("\n  Intel's table at the same points:")
        for ci, ch in ((0, 0), (2, 2), (3, 3)):
            pl = struct.unpack_from(f"<{n}H", d, 8 + ci * n * 2)
            ic = pl[(mh // 2) * mw + mw // 2] / mone
            ico = (pl[2*mw+2] + pl[2*mw+mw-3] + pl[(mh-3)*mw+2] + pl[(mh-3)*mw+mw-3]) / 4 / mone
            print(f"    {NAMES[ch]:<3}  {ico/ic:5.2f}x   (measured {need[ch]:5.2f}x,"
                  f" ratio {(ico/ic)/need[ch]:.2f})")

    if args.output:
        planes = []
        for ch in (0, 1, 2, 3):
            ref = means[ch][(GRID_H // 2) * GRID_W + GRID_W // 2]
            pl = []
            for v in means[ch]:
                gain = ref / v if v > 1e-6 else 1.0
                pl.append(max(ONE, min(int(gain * ONE), 8 * ONE)))
            planes.append(pl)
        with open(args.output, "wb") as f:
            f.write(struct.pack("<4H", GRID_W, GRID_H, ONE, 4))
            for pl in planes:
                f.write(struct.pack(f"<{len(pl)}H", *pl))
        print(f"\n  wrote {args.output}")


if __name__ == "__main__":
    sys.exit(main())
