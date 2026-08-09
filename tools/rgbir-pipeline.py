#!/usr/bin/env python3
"""Run the proposed RGB-IR pipeline offline, using Intel's own tuning data.

    raw 4x4 RGB-IR
      -> per-channel lens shading   (aiqb record 28, 63x47 grids)
      -> mosaic to R,G,B,IR         (phase from aiqb record 27/28 grid_indices)
      -> white balance              (aiqb chromaticity for the matched illuminant)
      -> colour correction matrix   (aiqb record 25)
      -> gamma 2.2

Everything except the raw frame comes out of the .aiqb. Nothing is hand-tuned.

    ./rgbir-pipeline.py <raw> <aiqb>

The .aiqb is Intel's proprietary tuning, extracted from a Windows install. It
is deliberately not committed to this repository - see docs/aiqb-format.md.
"""

import os
import struct
import sys

from PIL import Image, ImageDraw

PATTERN = [["G", "I", "G", "I"],
           ["R", "G", "B", "G"],
           ["G", "I", "G", "I"],
           ["B", "G", "R", "G"]]
# Channel index per position, as the aiqb's own grid_indices declares it.
CHAN = [[0, 1, 0, 1],
        [2, 3, 4, 3],
        [0, 1, 0, 1],
        [4, 3, 2, 3]]
LS = {0: "none", 1: "A", 2: "B", 3: "C", 4: "D50", 5: "D55", 6: "D65", 7: "D75",
      8: "F1", 9: "F2", 10: "F3", 11: "F4", 12: "F5", 13: "F6", 14: "F7",
      15: "F8", 16: "F9", 17: "F10", 18: "F11", 19: "F12", 20: "(20)"}


def records(a):
    o, out = 0xc0, {}
    while o + 8 <= len(a):
        size = struct.unpack_from("<I", a, o)[0]
        if size < 8 or o + size > len(a) or size % 4:
            break
        out[(a[o + 4], a[o + 6])] = (o, size)
        o += size
    return out


def read_ccm(a, o, size):
    """Record 25, cmc_advanced_color_matrix_correction."""
    n_ls, n_sec = struct.unpack_from("<HH", a, o + 8)
    base = o + 12 + 4 * n_sec
    stride = 4 + 8 + 8 + 36 + 36 * n_sec
    out = []
    for i in range(n_ls):
        p = base + i * stride
        st = struct.unpack_from("<I", a, p)[0]
        rg, bg = struct.unpack_from("<2f", a, p + 4)
        m = struct.unpack_from("<9f", a, p + 20)
        out.append((st, rg, bg, [list(m[r * 3:r * 3 + 3]) for r in range(3)]))
    return out


def read_lsc(a, o, size):
    """Record 28, cmc_lens_shading_correction. 30-byte preamble, then per
    light source a 22-byte header and one grid per distinct channel index."""
    # Four uint16 here, not three: num_light_srcs, num_grids, width, height.
    # Reading them two bytes early yielded nonsense light-source ids and a
    # gain floor of 0.00 where it should be ~1.0.
    n_ls, ngrid, gw, gh = struct.unpack_from("<HHHH", a, o + 24)
    base = o + 32
    per = 22 + ngrid * gw * gh * 2
    out = []
    for i in range(n_ls):
        p = base + i * per
        st = struct.unpack_from("<I", a, p)[0]
        grids = []
        for g in range(ngrid):
            q = p + 22 + g * gw * gh * 2
            grids.append(struct.unpack_from(f"<{gw*gh}H", a, q))
        out.append((st, grids))
    return out, gw, gh


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    rawpath, aiqbpath = sys.argv[1], sys.argv[2]
    for f in (rawpath, aiqbpath, rawpath + ".txt"):
        if not os.path.exists(f):
            sys.exit(f"missing: {f}")

    meta = open(rawpath + ".txt").read().split("\n")
    w, h, stride, _ = meta[0].split()
    w, h, stride = int(w), int(h), int(stride)
    black = [int(v) for v in meta[1].split()[1:]]
    raw = open(rawpath, "rb").read()
    a = open(aiqbpath, "rb").read()
    recs = records(a)

    W, H = w // 4, h // 4
    print(f"raw {w}x{h} -> {W}x{H} cells")

    # ---- planes, black-level corrected -------------------------------------
    P = {c: [0.0] * (W * H) for c in range(5)}
    cnt = {c: sum(1 for row in CHAN for x in row if x == c) for c in range(5)}
    for cy in range(H):
        rows = [(cy * 4 + dy) * stride for dy in range(4)]
        for cx in range(W):
            x2 = cx * 8
            acc = [0] * 5
            k = 0
            for dy, r in enumerate(rows):
                p = r + x2
                for dx in range(4):
                    acc[CHAN[dy][dx]] += (raw[p] | (raw[p + 1] << 8)) - black[k]
                    p += 2
                    k += 1
            i = cy * W + cx
            for c in range(5):
                P[c][i] = acc[c] / cnt[c]

    # ---- pick the illuminant by matching measured chromaticity -------------
    ccms = read_ccm(a, *recs[(100, 25)])
    mg = sum(P[0]) / len(P[0]) / 2 + sum(P[3]) / len(P[3]) / 2
    mr, mb = sum(P[2]) / len(P[2]), sum(P[4]) / len(P[4])
    meas = (mr / mg, mb / mg)
    st, rg, bg, M = min(ccms, key=lambda c: (c[1] - meas[0])**2 + (c[2] - meas[1])**2)
    print(f"measured R/G {meas[0]:.4f} B/G {meas[1]:.4f} -> illuminant "
          f"{LS.get(st, st)} (R/G {rg:.4f} B/G {bg:.4f})")

    # ---- lens shading, per channel -----------------------------------------
    lsc, gw, gh = read_lsc(a, *recs[(100, 28)])
    pick = min(range(len(lsc)), key=lambda i: 0 if lsc[i][0] == st else 1)
    grids = lsc[pick][1]
    print(f"lens shading: light source {LS.get(lsc[pick][0], lsc[pick][0])}, "
          f"{gw}x{gh} grids, gain {min(grids[0])/2048:.2f}-{max(grids[0])/2048:.2f}x")

    def shade(c, cx, cy):
        gx = cx / (W - 1) * (gw - 1)
        gy = cy / (H - 1) * (gh - 1)
        x0, y0 = int(gx), int(gy)
        x1, y1 = min(x0 + 1, gw - 1), min(y0 + 1, gh - 1)
        fx, fy = gx - x0, gy - y0
        g = grids[c]
        v = (g[y0 * gw + x0] * (1 - fx) * (1 - fy) + g[y0 * gw + x1] * fx * (1 - fy) +
             g[y1 * gw + x0] * (1 - fx) * fy + g[y1 * gw + x1] * fx * fy)
        return v / 2048.0

    # ---- assemble, white balance, CCM, gamma -------------------------------
    def render(use_lsc, use_ccm):
        out = bytearray(W * H * 3)
        gr, gb = 1.0 / rg, 1.0 / bg
        # normalise so a neutral scene keeps its level
        px = []
        for cy in range(H):
            for cx in range(W):
                i = cy * W + cx
                if use_lsc:
                    R = P[2][i] * shade(2, cx, cy)
                    G = (P[0][i] * shade(0, cx, cy) + P[3][i] * shade(3, cx, cy)) / 2
                    B = P[4][i] * shade(4, cx, cy)
                else:
                    R, G, B = P[2][i], (P[0][i] + P[3][i]) / 2, P[4][i]
                R, B = R * gr, B * gb
                if use_ccm:
                    R, G, B = (M[0][0]*R + M[0][1]*G + M[0][2]*B,
                               M[1][0]*R + M[1][1]*G + M[1][2]*B,
                               M[2][0]*R + M[2][1]*G + M[2][2]*B)
                px.append((R, G, B))
        ref = max(sorted(max(p[1], 0.0) for p in px)[int(len(px) * 0.99)], 1e-6)
        inv = 1 / 2.2
        for k, (R, G, B) in enumerate(px):
            for c, v in enumerate((R, G, B)):
                x = max(v, 0.0) / ref
                out[k * 3 + c] = min(255, round(min(x, 1.0) ** inv * 255))
        return Image.frombytes("RGB", (W, H), bytes(out))

    variants = [("WB only", render(False, False)),
                ("WB + lens shading", render(True, False)),
                ("WB + LSC + Intel CCM", render(True, True))]
    lab = 18
    sheet = Image.new("RGB", (W * 3 + 20, H + lab), (24, 24, 24))
    d = ImageDraw.Draw(sheet)
    for i, (nm, im) in enumerate(variants):
        sheet.paste(im, (i * (W + 10), lab))
        d.text((i * (W + 10) + 4, 4), f"{i+1}. {nm}", fill=(255, 255, 255))
        im.save(f"/tmp/rgbir-pipe-{i+1}.png")
    sheet.save("/tmp/rgbir-pipeline.png")
    print("\nwrote /tmp/rgbir-pipeline.png")


if __name__ == "__main__":
    main()
