#!/usr/bin/env python3
"""Fit a colour correction matrix from a captured colour target.

Captures the target from /dev/video0, samples the centre of each patch, and
least-squares fits the 3x3 matrix taking camera RGB to sRGB, both in linear
light. Writes a debug image showing exactly where it sampled so a bad alignment
is obvious rather than silently producing a bad matrix.

The fit is constrained so each row sums to 1. That keeps the matrix
white-preserving: neutral in stays neutral out, so it corrects hue and
saturation without disturbing the white balance that is already correct.

Usage:  solve-ccm.py capture   grab a frame and sample it
        solve-ccm.py fit       same, then fit and print the yaml
"""

import glob
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib.machinery import SourceFileLoader

_t = SourceFileLoader(
    "target", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "make-ccm-target.py")).load_module()
PATCHES, COLS, ROWS = _t.PATCHES, _t.COLS, _t.ROWS

HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.join(HERE, "..", "data")


def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def linear_to_srgb(v):
    v = max(0.0, min(1.0, v))
    return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


FRAME = os.path.join(OUTDIR, "ccm-capture.png")


def capture():
    """Grab a frame and keep it, so fit() scores the frame you verified."""
    tmp = tempfile.mkdtemp()
    try:
        subprocess.run(
            ["gst-launch-1.0", "-q", "v4l2src", "device=/dev/video0",
             "!", "videoconvert", "!", "videorate",
             "!", "video/x-raw,framerate=2/1",
             "!", "identity", "eos-after=6", "!", "pngenc",
             "!", "multifilesink", f"location={tmp}/f-%02d.png"],
            capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        sys.exit("capture timed out.\n"
                 "  Another process may still hold the camera - check with:\n"
                 "    pgrep -a gst-launch\n"
                 "  The CPU debayer is also slower; wait a few seconds and retry.")
    fs = sorted(glob.glob(tmp + "/f-*.png"))
    if not fs:
        sys.exit("no frames captured - is /dev/video0 free?")
    img = Image.open(fs[-1]).convert("RGB")
    os.makedirs(OUTDIR, exist_ok=True)
    img.save(FRAME)
    return img


def load_or_capture(reuse):
    """fit reuses the verified frame; capture always takes a fresh one."""
    if reuse and os.path.exists(FRAME):
        print(f"reusing {FRAME}  (delete it, or run 'capture', for a fresh frame)")
        return Image.open(FRAME).convert("RGB")
    return capture()


def sample(img):
    """Mean linear RGB of the middle third of each grid cell."""
    w, h = img.size
    px = img.load()
    out = []
    for i in range(len(PATCHES)):
        r, c = divmod(i, COLS)
        x0, x1 = c * w / COLS, (c + 1) * w / COLS
        y0, y1 = r * h / ROWS, (r + 1) * h / ROWS
        # middle third only, so slight misalignment does not bleed neighbours in
        mx0, mx1 = int(x0 + (x1 - x0) / 3), int(x1 - (x1 - x0) / 3)
        my0, my1 = int(y0 + (y1 - y0) / 3), int(y1 - (y1 - y0) / 3)
        acc = [0.0, 0.0, 0.0]
        peak = 0
        n = 0
        for y in range(my0, my1, 2):
            for x in range(mx0, mx1, 2):
                p = px[x, y]
                for k in range(3):
                    acc[k] += srgb_to_linear(p[k])
                peak = max(peak, p[0], p[1], p[2])
                n += 1
        out.append(([a / n for a in acc], peak))
    return out


def debug_image(img, path):
    d = ImageDraw.Draw(img)
    w, h = img.size
    for i in range(len(PATCHES)):
        r, c = divmod(i, COLS)
        x0, x1 = c * w / COLS, (c + 1) * w / COLS
        y0, y1 = r * h / ROWS, (r + 1) * h / ROWS
        mx0, mx1 = int(x0 + (x1 - x0) / 3), int(x1 - (x1 - x0) / 3)
        my0, my1 = int(y0 + (y1 - y0) / 3), int(y1 - (y1 - y0) / 3)
        d.rectangle([mx0, my0, mx1, my1], outline=(255, 0, 255), width=2)
    img.save(path)


def solve(cam, ref):
    """Least squares, one output channel at a time, rows constrained to sum 1.

    Substituting m3 = 1 - m1 - m2 turns each row into an unconstrained 2x2
    problem, which is small enough to solve directly without numpy.
    """
    m = []
    for k in range(3):
        s11 = s12 = s22 = b1 = b2 = 0.0
        for c, t in zip(cam, ref):
            x1, x2 = c[0] - c[2], c[1] - c[2]
            y = t[k] - c[2]
            s11 += x1 * x1
            s12 += x1 * x2
            s22 += x2 * x2
            b1 += x1 * y
            b2 += x2 * y
        det = s11 * s22 - s12 * s12
        if abs(det) < 1e-12:
            sys.exit("singular fit - the patches are too similar; check alignment")
        a = (b1 * s22 - b2 * s12) / det
        b = (s11 * b2 - s12 * b1) / det
        m.append([a, b, 1.0 - a - b])
    return m


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "fit"
    os.makedirs(OUTDIR, exist_ok=True)

    img = load_or_capture(reuse=(mode == "fit"))
    sampled = sample(img)
    cam = [c for c, _pk in sampled]
    peaks = [pk for _c, pk in sampled]
    dbg = os.path.join(OUTDIR, "ccm-sampling.png")
    debug_image(img.copy(), dbg)

    ref = [[srgb_to_linear(v) for v in rgb] for _name, rgb in PATCHES]

    print(f"sampled {len(cam)} patches from a {img.size[0]}x{img.size[1]} frame")
    print(f"check the alignment: {dbg}\n")
    print(f"  {'patch':<15} {'camera (sRGB)':>16}   {'target (sRGB)':>16}")
    CLIP = 248
    for (name, rgb), c, pk in zip(PATCHES, cam, peaks):
        cs = tuple(round(linear_to_srgb(v) * 255) for v in c)
        flag = "  CLIPPED" if pk >= CLIP else ""
        print(f"  {name:<15} {str(cs):>16}   {str(rgb):>16}{flag}")

    clipped = [PATCHES[i][0] for i, pk in enumerate(peaks) if pk >= CLIP]

    # The last six patches are a neutral ramp, 243 -> 52. If the bright end is
    # compressed the exposure is too high, even when nothing has hit 255 yet:
    # several distinct targets collapse onto one camera value and the fit
    # cannot separate them. That is what produced a matrix building red out of
    # blue on the first attempt.
    ramp = [sum(cam[i]) / 3 for i in range(18, 24)]
    steps = [ramp[i] - ramp[i + 1] for i in range(5)]
    flat = sum(1 for st in steps if st <= 0.002)

    # Neutral patches say whether white balance is still right; a CCM cannot
    # fix a white balance error and should not be asked to.
    wh = cam[18]
    print(f"\n  white patch ratios: R/G {wh[0]/wh[1]:.3f}  B/G {wh[2]/wh[1]:.3f}"
          "   (want ~1.000)")

    print(f"\n  neutral ramp (white -> black), linear:")
    print("    " + "  ".join(f"{v:.3f}" for v in ramp))
    if clipped:
        print(f"\n  {len(clipped)} patch(es) clipped at >= {CLIP}/255: "
              + ", ".join(clipped))
    if flat:
        print(f"  {flat} step(s) of the neutral ramp are flat - highlights compressed")

    if mode != "fit":
        return

    # Exclude saturated patches rather than demanding none. On this sensor blue
    # is weak, so white (which needs blue) is dim while yellow (which does not)
    # is bright - there may be no exposure at which both are well behaved.
    # Standard practice is to drop the saturated samples and fit the rest.
    # Also drop very dark patches. There is an additive offset in the shadows -
    # residual black level or veiling glare - and blue's 4.9x gain amplifies it
    # 3.4x more than red's, so B/G runs from 7.9 at black to 1.07 by mid grey.
    # Fitting a multiplicative matrix to an additive artefact is what wrecked
    # the blue row. DARK_FLOOR can be raised with CCM_DARK_FLOOR=0.3 etc.
    DARK_FLOOR = float(os.environ.get("CCM_DARK_FLOOR", "0.25"))
    dark = [i for i, c in enumerate(cam) if sum(c) / 3 < DARK_FLOOR]
    usable = [i for i, pk in enumerate(peaks)
              if pk < CLIP and i not in dark]
    if dark:
        print(f"\n  excluding {len(dark)} dark patch(es) below {DARK_FLOOR} linear"
              " (shadow offset corrupts these): "
              + ", ".join(PATCHES[i][0] for i in dark))
    if clipped:
        print(f"\n  excluding {len(clipped)} saturated patch(es) from the fit: "
              + ", ".join(clipped))
    if flat:
        print("  note: part of the neutral ramp is compressed; those patches"
              " contribute little")

    if mode != "fit":
        return

    MIN_PATCHES = 12
    if len(usable) < MIN_PATCHES:
        white8 = round(linear_to_srgb(sum(cam[18]) / 3) * 255)
        print(f"\n  REFUSING TO FIT - only {len(usable)} usable patches,"
              f" need {MIN_PATCHES}.")
        print("  Patches that are indistinguishable make several distinct targets")
        print("  share one camera value, and least squares cannot separate them -")
        print("  the result looks like a matrix but is meaningless.")
        print(f"  white patch reads {white8}/255")
        if white8 > 240:
            print("  -> TOO BRIGHT. Lower the screen brightness and re-capture.")
        elif white8 < 120:
            print("  -> TOO DARK. Raise the screen brightness and re-capture.")
        else:
            print("  -> check alignment in data/ccm-sampling.png")
        raise SystemExit(1)

    cam_fit = [cam[i] for i in usable]
    ref_fit = [ref[i] for i in usable]
    print(f"\n  fitting on {len(usable)} of {len(cam)} patches")
    m = solve(cam_fit, ref_fit)
    print("\nfitted matrix (camera RGB -> sRGB, linear, rows sum to 1):")
    for row in m:
        print("   " + "  ".join(f"{v:+.4f}" for v in row))

    before = sum(sum(abs(c[k] - t[k]) for k in range(3))
                 for c, t in zip(cam_fit, ref_fit))
    after = 0.0
    for c, t in zip(cam_fit, ref_fit):
        for k in range(3):
            after += abs(sum(m[k][j] * c[j] for j in range(3)) - t[k])
    n = len(cam_fit) * 3
    print(f"\n  mean abs error, linear:  before {before/n:.4f}   after {after/n:.4f}")
    diag_ok = all(abs(m[k][k]) >= max(abs(m[k][j]) for j in range(3)) for k in range(3))
    print("  matrix is diagonally dominant" if diag_ok else
          "  WARNING: not diagonally dominant - treat this result with suspicion")

    flat = ", ".join(f"{v:.4f}" for row in m for v in row)
    print("\nadd to libcamera/ov5675.yaml, before the Awb entry:\n")
    print("  - Ccm:")
    print("      ccms:")
    print("        - ct: 6750")
    print(f"          ccm: [ {flat} ]")


if __name__ == "__main__":
    main()
