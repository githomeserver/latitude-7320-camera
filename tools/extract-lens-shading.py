#!/usr/bin/env python3
"""Extract Intel's lens shading tables from an .aiqb into a usable gain map.

Record 100/28, lens_shading_correction_4x4. Layout was established in
docs/aiqb-format.md; this only reads it. Nothing here is guessed - the file
carries its own channel map and grid dimensions, and the result is checked
against the radial profile the doc recorded independently.

    ./extract-lens-shading.py OV5678_0BF501T3_TGL.aiqb [-o shading.bin]

Intel tracks five channels (the two greens separately, as Gr/Gb in Bayer);
RgbIrToBayer::ShadingMap has four. The two greens are averaged, which is right
here because the pre-pass already averages green samples within the cell.
"""

import argparse
import struct
import sys

CHANNEL_NAMES = {0: "G(even)", 1: "IR", 2: "R", 3: "G(odd)", 4: "B"}
ONE = 2048          # fixed point: 2048 == 1.0x gain
TYPE_LSC_4X4 = 28


def records(data):
    """Walk the CPFF container and yield (format_id, group_id, type_id, body)."""
    if data[:4] != b"CPFF":
        raise SystemExit("not a CPFF container")
    off = 0xC0                      # records start here, per the container walk
    while off + 8 <= len(data):
        size, fmt, grp, typ, _ = struct.unpack_from("<IBBBB", data, off)
        if size < 8 or off + size > len(data):
            break
        yield fmt, grp, typ, data[off + 8:off + size]
        off += size


def parse_lsc(body):
    """Return (channel_map, width, height, planes) with planes[i] a gain list."""
    cmap = list(body[:16])
    n_illum, n_chan, width, height = struct.unpack_from("<4H", body, 16)

    preamble = 38
    per_plane = 2 + width * height          # in uint16 units
    n_planes = n_illum * n_chan
    expected = preamble + n_planes * per_plane * 2
    if expected != len(body):
        raise SystemExit(
            f"layout mismatch: {n_illum} illum x {n_chan} chan x ({width}x{height}) "
            f"=> {expected} bytes, record body is {len(body)}")

    planes = []
    for p in range(n_planes):
        base = preamble + p * per_plane * 2
        hdr = struct.unpack_from("<2H", body, base)
        gains = struct.unpack_from(f"<{width*height}H", body, base + 4)
        planes.append((hdr, gains))
    return cmap, n_illum, n_chan, width, height, planes


def radial_profile(gains, w, h):
    """Mean gain in radial bins, normalised radius 1.0 = half-diagonal."""
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    rmax = (cx ** 2 + cy ** 2) ** 0.5
    bins, counts = [0.0] * 8, [0] * 8
    for y in range(h):
        for x in range(w):
            r = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / rmax
            b = min(7, int(r * 5))          # bins of 0.2 in r, last one catches corners
            bins[b] += gains[y * w + x]
            counts[b] += 1
    return [(i * 0.2, bins[i] / counts[i] / ONE) for i in range(8) if counts[i]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("aiqb")
    ap.add_argument("-o", "--output", help="write a 4-channel map for ShadingMap")
    ap.add_argument("--illuminant", type=int, default=0)
    args = ap.parse_args()

    data = open(args.aiqb, "rb").read()
    body = None
    for fmt, grp, typ, b in records(data):
        if typ == TYPE_LSC_4X4:
            body = b
            print(f"  record {grp}/{typ}: {len(b) + 8} bytes")
            break
    if body is None:
        raise SystemExit("no lens_shading_correction_4x4 record (type 28)")

    cmap, n_illum, n_chan, w, h, planes = parse_lsc(body)

    print("  4x4 channel map:")
    for r in range(4):
        row = " ".join(f"{cmap[r*4+c]}" for c in range(4))
        cols = " ".join(CHANNEL_NAMES[cmap[r*4+c]][0] for c in range(4))
        print(f"    {row}    {cols}")
    print(f"  {n_illum} illuminants x {n_chan} channels, {w}x{h} grid, {len(planes)} planes")

    # Establish plane ordering from the data rather than assuming it: with
    # channel-major ordering, planes n_illum apart share a channel; with
    # illuminant-major, planes 1 apart do. IR is far flatter than the colour
    # channels, so its position gives the ordering away.
    means = [sum(g) / len(g) / ONE for _, g in planes]
    print(f"  plane mean gains, first {min(10, len(means))}: "
          + " ".join(f"{m:.2f}" for m in means[:10]))

    ill = args.illuminant
    base = ill * n_chan
    print(f"\n  illuminant {ill}, per-channel radial profile (gain vs normalised radius):")
    print("    channel      r=0.0  r=0.2  r=0.4  r=0.6  r=0.8  r=1.0+")
    for c in range(n_chan):
        prof = radial_profile(planes[base + c][1], w, h)
        vals = " ".join(f"{g:5.2f}" for _, g in prof[:6])
        print(f"    plane {c} ({CHANNEL_NAMES.get(c,'?'):>7}) {vals}")

    if args.output:
        # Collapse Intel's five channels onto ShadingMap's four, averaging the
        # two greens. Order matches RgbIrToBayer::Channel: G, IR, R, B.
        g0, g1 = planes[base + 0][1], planes[base + 3][1]
        green = [(a + b) // 2 for a, b in zip(g0, g1)]
        out = [green, planes[base + 1][1], planes[base + 2][1], planes[base + 4][1]]
        with open(args.output, "wb") as f:
            f.write(struct.pack("<4H", w, h, ONE, 4))
            for ch in out:
                f.write(struct.pack(f"<{w*h}H", *ch))
        print(f"\n  wrote {args.output}: {w}x{h}, 4 channels (G, IR, R, B), one={ONE}")


if __name__ == "__main__":
    sys.exit(main())
