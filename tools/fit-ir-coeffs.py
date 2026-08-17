#!/usr/bin/env python3
"""Fit per-channel IR subtraction coefficients AND the colour matrix together.

WHY PER-CHANNEL

Every photosite on an RGB-IR sensor responds to near infrared, so each colour
channel carries an IR pedestal that washes colour out. The pre-pass removes
k * IR from all three channels with ONE k, which assumes red, green and blue
have identical infrared sensitivity. They do not. Measured on the chart, a
single k trades one fault for another: too little and everything stays
desaturated (blue reads B/G 1.05 against a 2.46 target), too much and the
shadows go magenta because green is driven negative first.

WHY IT MUST BE FITTED ON RAW

The processed frame is useless for this. It has been through the debayer, the
AWB gains, a colour matrix and a gamma curve, and the IR plane has been thrown
away entirely - so the very quantity being solved for is not in the picture. The
mosaic has R, G, B and IR each measured directly at known positions, in linear
counts, with nothing applied. This is the same reason the lens shading had to be
measured from raw.

WHY JOINTLY

k and the matrix are not independent: a larger k leaves less for the matrix to
do. Fitting the matrix alone against a poorly separated signal is what produced
off-diagonals of -2 to +4 and a matrix that was not diagonally dominant. Solving
both together lets the physical correction do the physical work and leaves the
matrix a well conditioned job.

    ./fit-ir-coeffs.py <dir with rawcam0-stream0-*.bin>
"""

import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "ccmtarget", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "make-ccm-target.py"))
_t = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_t)
PATCHES, COLS, ROWS = _t.PATCHES, _t.COLS, _t.ROWS

W, H = 2592, 1944
BLACK = 64
CLIP = 1000                     # 10-bit; leave headroom below 1023

# G I G I / R G B G / G I G I / B G R G  -> 0=G 1=IR 2=R 3=B
PATTERN = [0, 1, 0, 1,
           2, 0, 3, 0,
           0, 1, 0, 1,
           3, 0, 2, 0]
NAMES = ("G", "IR", "R", "B")


def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def patch_means(paths):
    """Mean R,G,B,IR in linear counts for each patch, averaged over frames.

    Samples the middle half of each cell only. The chart is displayed edge to
    edge, so cell boundaries land inside the frame and a full-cell average would
    mix neighbours in wherever the alignment is a pixel or two out.
    """
    n_patch = COLS * ROWS
    sums = [[0.0] * 4 for _ in range(n_patch)]
    cnts = [[0] * 4 for _ in range(n_patch)]
    clipped = set()

    for p in paths:
        raw = open(p, "rb").read()
        if len(raw) != W * H * 2:
            continue
        mv = memoryview(raw).cast("H")
        for i in range(n_patch):
            r, c = divmod(i, COLS)
            x0 = int((c + 0.25) * W / COLS)
            x1 = int((c + 0.75) * W / COLS)
            y0 = int((r + 0.25) * H / ROWS)
            y1 = int((r + 0.75) * H / ROWS)
            # Whole 4x4 cells, spaced out. A plain stride of 2 lands on only
            # two of the four channels, and WHICH two depends on whether the
            # window happens to start on an even row - here it starts at y=121,
            # so green and IR read exactly zero. Walking complete cells makes
            # the sampling independent of alignment.
            y0 -= y0 % 4
            x0 -= x0 % 4
            for cy in range(y0, y1 - 3, 8):
                for dy in range(4):
                    y = cy + dy
                    base = y * W
                    prow = (dy % 4) * 4
                    for cx in range(x0, x1 - 3, 8):
                        for dx in range(4):
                            v = mv[base + cx + dx]
                            ch = PATTERN[prow + dx]
                            if v >= CLIP:
                                clipped.add(i)
                            sums[i][ch] += max(0, v - BLACK)
                            cnts[i][ch] += 1
    means = [[s / k if k else 0.0 for s, k in zip(sums[i], cnts[i])]
             for i in range(n_patch)]
    return means, clipped


def solve_matrix(cam, ref):
    """Least squares 3x3 with each row constrained to sum to 1.

    Row sums of 1 keep the matrix white preserving, so it corrects hue and
    saturation without moving the white balance. Each output row is independent,
    so this is three small constrained problems, solved by eliminating the third
    unknown via the constraint.
    """
    m = []
    for k in range(3):
        # minimise sum_i (a*(x0-x2) + b*(x1-x2) + x2 - t)^2
        a11 = a12 = a22 = b1 = b2 = 0.0
        for c, t in zip(cam, ref):
            u, v = c[0] - c[2], c[1] - c[2]
            d = t[k] - c[2]
            a11 += u * u
            a12 += u * v
            a22 += v * v
            b1 += u * d
            b2 += v * d
        det = a11 * a22 - a12 * a12
        if abs(det) < 1e-12:
            m.append([1.0 if j == k else 0.0 for j in range(3)])
            continue
        a = (b1 * a22 - b2 * a12) / det
        b = (b2 * a11 - b1 * a12) / det
        m.append([a, b, 1.0 - a - b])
    return m


def error_of(cam, ref, m):
    e = 0.0
    for c, t in zip(cam, ref):
        for k in range(3):
            e += abs(sum(m[k][j] * c[j] for j in range(3)) - t[k])
    return e / (len(cam) * 3)


def evaluate(means, ref, usable, white_i, kr, kg, kb):
    """Subtract k*IR per channel, white balance on the white patch, fit M."""
    corr = []
    for mn in means:
        ir = mn[1]
        corr.append([mn[2] - kr * ir, mn[0] - kg * ir, mn[3] - kb * ir])
    wh = corr[white_i]
    if min(wh) <= 1e-6:
        return None
    # Normalise so white is 1,1,1: this is what the runtime AWB does, and it
    # keeps the matrix from spending its freedom on white balance.
    norm = [[c[0] / wh[0], c[1] / wh[1], c[2] / wh[2]] for c in corr]
    if any(min(norm[i]) < -0.05 for i in usable):
        return None                     # over-subtracted into negative signal
    cam_fit = [norm[i] for i in usable]
    ref_fit = [ref[i] for i in usable]
    m = solve_matrix(cam_fit, ref_fit)
    return error_of(cam_fit, ref_fit, m), m, norm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--max-k", type=float, default=4.0)
    ap.add_argument("--step", type=float, default=0.25)
    args = ap.parse_args()

    paths = sorted(glob.glob(os.path.join(args.dir, "rawcam0-stream0-*.bin")))
    if not paths:
        raise SystemExit(f"no raw frames in {args.dir}")
    print(f"  averaging {len(paths)} raw frames")
    means, clipped = patch_means(paths)

    names = [p[0] for p in PATCHES]
    n_patch = COLS * ROWS
    ref_all = [[srgb_to_linear(v) for v in rgb] for _n, rgb in PATCHES]

    # Is this actually a colour chart?
    #
    # It has to be asked. The sensor module is mounted rotated 180 degrees and
    # the pipeline undoes that downstream, so a raw frame may be upside down
    # relative to the picture the chart was aligned against - and separately, the
    # chart may simply not be on screen any more. Both were true here: 90 raw
    # frames were fitted to a dark room, produced 6-56 counts per patch and a
    # "black" brighter than "white", and the solver reported an answer anyway.
    #
    # The neutral row is the test. White through black must fall monotonically.
    # Score both orientations and take the better; if neither looks like a ramp,
    # refuse rather than fit noise.
    neutrals = [names.index(n) for n in
                ("white", "neutral 8", "neutral 6.5", "neutral 5",
                 "neutral 3.5", "black") if n in names]

    def ramp_score(mm):
        vals = [mm[i][0] for i in neutrals]          # green channel
        if min(vals) <= 0:
            return -1.0, vals
        good = sum(1 for a, b in zip(vals, vals[1:]) if a > b)
        return good / max(1, len(vals) - 1), vals

    flipped = list(reversed(means))
    s_norm, v_norm = ramp_score(means)
    s_flip, v_flip = ramp_score(flipped)
    if s_flip > s_norm:
        print("  raw frame is rotated 180 degrees relative to the target - "
              "reindexing")
        means, score, vals = flipped, s_flip, v_flip
    else:
        means, score, vals = means, s_norm, v_norm

    print("  neutral ramp, green counts (white -> black): "
          + " ".join(f"{v:.0f}" for v in vals))
    if score < 0.8 or max(vals) < 120:
        print(f"\n  REFUSING TO FIT: this does not look like the colour chart.")
        print(f"  Monotonic steps {score*100:.0f}% (want >=80%), "
              f"brightest neutral {max(vals):.0f} counts (want >=120).")
        print("  Either the target is not on screen, it does not fill the frame,")
        print("  or the scene is far too dark. Nothing was fitted.")
        raise SystemExit(2)

    ref = ref_all
    white_i = names.index("white") if "white" in names else 18

    print("\n  patch            R      G      B     IR    IR/G")
    for i, nm in enumerate(names):
        r, g, b, ir = means[i][2], means[i][0], means[i][3], means[i][1]
        flag = "  CLIPPED" if i in clipped else ""
        print(f"  {nm:<14} {r:6.1f} {g:6.1f} {b:6.1f} {ir:6.1f}  "
              f"{ir/g if g else 0:5.3f}{flag}")

    # Exclude clipped patches and any too close to the pedestal to mean anything.
    usable = [i for i in range(len(means))
              if i not in clipped and means[i][0] > 12 and means[i][1] > 2]
    print(f"\n  usable patches: {len(usable)} of {len(means)}"
          + (f"; clipped: {', '.join(names[i] for i in sorted(clipped))}" if clipped else ""))
    if white_i not in usable:
        raise SystemExit("the white patch is clipped or too dark - cannot normalise")

    best = None
    n = int(args.max_k / args.step) + 1
    for i in range(n):
        for j in range(n):
            for l in range(n):
                kr, kg, kb = i * args.step, j * args.step, l * args.step
                got = evaluate(means, ref, usable, white_i, kr, kg, kb)
                if got is None:
                    continue
                if best is None or got[0] < best[0]:
                    best = (got[0], (kr, kg, kb), got[1])

    # For comparison, the best single k, which is what ships today.
    best_scalar = None
    for i in range(n):
        k = i * args.step
        got = evaluate(means, ref, usable, white_i, k, k, k)
        if got is None:
            continue
        if best_scalar is None or got[0] < best_scalar[0]:
            best_scalar = (got[0], k, got[1])

    if best is None:
        raise SystemExit("no usable coefficient combination")

    err, (kr, kg, kb), m = best
    print(f"\n  best single k  = {best_scalar[1]:.2f}      error {best_scalar[0]:.4f}")
    print(f"  best per-channel: kR={kr:.2f} kG={kg:.2f} kB={kb:.2f}   error {err:.4f}"
          f"   ({100*(1-err/best_scalar[0]):+.1f}% vs scalar)")

    def dom(mm):
        return all(abs(mm[k][k]) >= max(abs(mm[k][j]) for j in range(3))
                   for k in range(3))

    for label, mm in (("scalar", best_scalar[2]), ("per-channel", m)):
        print(f"\n  matrix ({label}):"
              + ("  diagonally dominant" if dom(mm) else "  NOT diagonally dominant"))
        for row in mm:
            print("     " + "  ".join(f"{v:+.4f}" for v in row))

    flat = ", ".join(f"{v:.4f}" for row in m for v in row)
    print(f"\n  RGBIR_IRSUB_R={kr:.2f} RGBIR_IRSUB_G={kg:.2f} RGBIR_IRSUB_B={kb:.2f}")
    print(f"  ccm: [ {flat} ]")


if __name__ == "__main__":
    sys.exit(main())
