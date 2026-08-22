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
import re
import subprocess
import time
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


def reported_ct():
    """The colour temperature THIS pipeline reports for the current light.

    The CCM entry's "ct" is not a physical measurement - it is the key libcamera
    interpolates on, and the value it compares against comes from this AWB's own
    estimateCCT() over its grey-world gains. So the label has to be whatever the
    estimator says under the light the matrix was fitted for, or interpolation
    picks the wrong matrix.

    This bit us once already: the installed entry says ct 3100 because that is
    what the sensor reported indoors in August, before the AWB gain clamp was
    removed and IR subtraction and lens shading were added. The same room now
    reads 4483. With one matrix that is harmless, since it is applied whatever
    the temperature; with two it would silently blend the wrong pair.
    """
    env = dict(os.environ)
    env.update({
        "LD_LIBRARY_PATH": "/usr/local/lib/x86_64-linux-gnu",
        "LIBCAMERA_IPA_MODULE_PATH": "/usr/local/lib/x86_64-linux-gnu/libcamera/ipa",
        "LIBCAMERA_RGBIR": "1",
        "LIBCAMERA_SOFTISP_MODE": "cpu",
        "LIBCAMERA_LOG_LEVELS": "IPASoftAwb:DEBUG",
    })
    # cam needs exclusive access to the libcamera camera, which the always-on
    # service holds. Without this the probe silently fails and the entry gets
    # labelled with the fallback, which is the very bug this function exists to
    # prevent.
    svc = "ov5678-camera.service"
    was_up = subprocess.run(["systemctl", "is-active", "--quiet", svc]).returncode == 0
    if was_up:
        subprocess.run(["sudo", "-n", "systemctl", "stop", svc],
                       capture_output=True)
        time.sleep(1)
    try:
        r = subprocess.run(
            ["/usr/local/bin/cam", "-c1", "-s", "width=1280,height=720", "-C60"],
            capture_output=True, text=True, timeout=120, env=env)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    finally:
        if was_up:
            subprocess.run(["sudo", "-n", "systemctl", "start", svc],
                           capture_output=True)
            time.sleep(3)
    vals = re.findall(r"temperature: (\d+)", r.stdout + r.stderr)
    if len(vals) < 10:
        return None
    tail = [int(v) for v in vals[-20:]]          # after AWB has settled
    tail.sort()
    return tail[len(tail) // 2]


def reap_stale_consumers():
    """Kill leftover gst readers of the loopback before capturing.

    A timed-out capture can leave its gst-launch alive holding /dev/video0. The
    next attempt then dies with "not-negotiated (-4)" and times out as well,
    which looks like the camera being mysteriously busy - and every retry adds
    another orphan. Seen exactly that twice.

    Matching is on the process NAME plus a read of its cmdline, never
    `pgrep -f v4l2src`: a -f pattern also matches the shell command that
    contains it, so the sweep kills its own caller. That happened too.
    """
    prod = subprocess.run(["systemctl", "show", "-p", "MainPID", "--value",
                           "ov5678-camera.service"],
                          capture_output=True, text=True).stdout.strip()
    try:
        pids = subprocess.run(["pgrep", "-x", "gst-launch-1.0"],
                              capture_output=True, text=True).stdout.split()
    except FileNotFoundError:
        return
    killed = 0
    for pid in pids:
        if pid == prod:
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if "v4l2src" in cmd and "/dev/video0" in cmd:
            subprocess.run(["kill", "-9", pid], capture_output=True)
            killed += 1
    if killed:
        print(f"  cleared {killed} stale reader(s) of /dev/video0")
        time.sleep(1)


def exposure_headroom():
    """Report whether the sensor has room to expose, from its own controls.

    Two failure modes look similar in the patch numbers and have opposite fixes.
    Too bright and the top patches clip, so the fit loses its white anchor. Too
    dim and the sensor pegs exposure AND analogue gain at maximum, so everything
    lands in the bottom third of the range at maximum noise, and the AWB starts
    drifting too. Both were hit here within ten minutes, in that order.

    Reading the subdev says which, instead of guessing from the picture.
    """
    for sd in sorted(glob.glob("/dev/v4l-subdev*")):
        try:
            out = subprocess.run(["v4l2-ctl", "-d", sd, "--list-ctrls"],
                                 capture_output=True, text=True, timeout=10).stdout
        except (subprocess.TimeoutExpired, FileNotFoundError):
            continue
        if "exposure" not in out or "analogue_gain" not in out:
            continue
        got = {}
        for line in out.splitlines():
            m = re.search(r"(exposure|analogue_gain)\s+0x\w+\s+\(int\)\s+:\s+"
                          r"min=(\d+) max=(\d+).*value=(\d+)", line)
            if m:
                got[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
        if len(got) == 2:
            return got
    return None


def capture():
    """Grab a frame and keep it, so fit() scores the frame you verified."""
    reap_stale_consumers()
    tmp = tempfile.mkdtemp()
    try:
        # No videorate. It was there to space six frames two seconds apart so
        # the AGC could settle, but it stalls intermittently against a loopback
        # holding only two buffers - hanging the whole capture for no reason
        # anyone could see. The spacing is not needed anyway: the producer runs
        # continuously, so exposure and white balance are already converged
        # before this reader ever attaches. Just take a run of frames and keep
        # the last.
        # 240 frames, keep the last. The comment above used to justify 60 by
        # saying the producer runs continuously so exposure is already settled
        # when this reader attaches. That stopped being true when the pipeline
        # moved to starting ON DEMAND: attaching is what starts it, so the first
        # frames are the AGC's own convergence. It walks in ~10% steps at a
        # quarter of the frame rate and takes about four seconds to come down
        # from clipping, so a 60-frame capture was sampling the middle of that -
        # which is why the same scene reported clipped one minute and dim the
        # next. 240 frames is eight seconds; the last one is settled.
        subprocess.run(
            ["gst-launch-1.0", "-q", "v4l2src", "device=/dev/video0",
             "num-buffers=240", "!", "videoconvert", "!", "pngenc",
             "!", "multifilesink", f"location={tmp}/f-%03d.png"],
            capture_output=True, timeout=180)
    except subprocess.TimeoutExpired:
        sys.exit("capture timed out.\n"
                 "  Another process may still hold the camera - check with:\n"
                 "    pgrep -a gst-launch\n"
                 "  The CPU debayer is also slower; wait a few seconds and retry.")
    hr = exposure_headroom()
    if hr:
        e_min, e_max, e = hr["exposure"]
        g_min, g_max, g = hr["analogue_gain"]
        print(f"  sensor: exposure {e}/{e_max}, analogue gain {g}/{g_max}")
        if e >= e_max and g >= g_max:
            print("  WARNING: exposure AND gain are both at maximum - the scene is")
            print("  too dim to fit from. Raise the target's brightness a couple of")
            print("  steps; everything will otherwise sit in the bottom third of the")
            print("  range at maximum noise.")

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

    # fit captures FRESH unless --reuse is given. Reusing by default has now
    # silently scored a stale frame twice in this project: once a capture from a
    # different machine, and once one shot at a different screen brightness,
    # both producing a confidently wrong matrix. Whatever is on screen now is
    # what gets fitted.
    reuse = "--reuse" in sys.argv
    img = load_or_capture(reuse=reuse)
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
    # A clipped white patch reads (255, 255, 255), which gives ratios of exactly
    # 1.000 whatever the white balance actually is. That is not a good reading,
    # it is no reading at all - and it is convincing enough to have been taken
    # for a healthy white balance across several captures here, while the honest
    # figure at an unclipped exposure was R/G 0.450. Say so instead.
    if peaks[18] >= CLIP:
        print(f"\n  white patch ratios: UNMEASURABLE - the white patch is clipped"
              f" (peak {peaks[18]}/255).")
        print("  Clipped channels pin to 255 and read back as a perfect 1.000."
              " Lower the exposure and re-capture.")
    else:
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

    # Neutralise any residual white balance error BEFORE fitting.
    #
    # The comment above is right that a CCM cannot fix a white balance error and
    # should not be asked to - but nothing acted on it, so a cast in the capture
    # went straight into the solve. The row-sum-to-1 constraint only keeps
    # neutrals neutral if the neutral input is already equal-RGB; with a cast it
    # does not, and the solver spends its freedom on white balance instead of
    # hue and saturation. A dimmed target here read R/G 0.813, and the matrix
    # came out with off-diagonals of -2 and +3.
    #
    # Scaling R and B so the white patch is neutral is what the runtime AWB does
    # anyway, so the matrix that comes out is the pure colour part.
    wb = [wh[1] / wh[0] if wh[0] > 1e-6 else 1.0,
          1.0,
          wh[1] / wh[2] if wh[2] > 1e-6 else 1.0]
    if max(abs(wb[0] - 1.0), abs(wb[2] - 1.0)) > 0.02:
        print(f"\n  neutralising a white balance error before fitting: "
              f"R x{wb[0]:.3f}  B x{wb[2]:.3f}")
        cam = [[c[0] * wb[0], c[1], c[2] * wb[2]] for c in cam]
        wh2 = cam[18]
        print(f"  white patch after: R/G {wh2[0]/wh2[1]:.3f}  B/G {wh2[2]/wh2[1]:.3f}")

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
    ct = reported_ct()
    if ct is None:
        ct = 6750
        print("\n  WARNING: could not read the reported colour temperature;")
        print("  falling back to 6750. Set the ct by hand - a wrong label makes")
        print("  interpolation choose the wrong matrix once a second one exists.")
    else:
        print(f"\n  this pipeline reports {ct} K under the light you just shot in")

    print("\nadd to libcamera/ov5675.yaml, before the Awb entry:\n")
    print("  - Ccm:")
    print("      ccms:")
    print(f"        - ct: {ct}")
    print(f"          ccm: [ {flat} ]")


if __name__ == "__main__":
    main()
