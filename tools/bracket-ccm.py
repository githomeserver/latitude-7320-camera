#!/usr/bin/env python3
"""Fit a colour matrix from an exposure bracket, so every patch is usable.

WHY A BRACKET

A full-screen emissive target does not fit inside one exposure on this camera.
It floods the lens with veiling flare, which lifts black to about 0.085 linear
against a target of 0.033, and the bright warm patches clip before the deep
colours climb above that floor. Measured on this hardware, a single exposure
left 12 of 24 patches usable at best - and the twelve it threw away were exactly
the ones that pin down the red row: orange, orange yellow, yellow and white
saturated, while blue, green, cyan, purple and the deep neutrals were too dark.
The matrices that came out said so, building red mostly out of green and moving
30% on a small exposure change.

Shooting the same target at several known analogue gains fixes it. A patch that
clips at high gain is read from a lower one; a patch lost in the floor at low
gain is read from a higher one. Because the gains are known exactly, the samples
can be put back on a common scale and fitted together.

WHY THE GAINS ARE EXACT

Not because we asked for them. The requested gain is quantised by the sensor -
the register is gain x 128 - so the tool reads back what the sensor actually
applied from the subdev and scales by that, never by the request. Analogue gain
multiplies photons and flare alike, and the black pedestal is removed upstream
before it, so after black subtraction the whole frame scales linearly with it.
That is what makes the rescale valid.

Requires the fixed-exposure IPA patch (upstream-libcamera/0002-*), since the
camera registers no exposure controls at all.

Run as root, with the target filling the frame:
    sudo tools/bracket-ccm.py            # default gain ladder
    sudo tools/bracket-ccm.py 1.0 2.0 4.0
"""

import os
import subprocess
import sys
import time

from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
_s = SourceFileLoader("solveccm", os.path.join(HERE, "solve-ccm.py")).load_module()

PATCHES = _s.PATCHES
srgb_to_linear, linear_to_srgb = _s.srgb_to_linear, _s.linear_to_srgb
sample, solve, capture = _s.sample, _s.solve, _s.capture
exposure_headroom, debug_image = _s.exposure_headroom, _s.debug_image
OUTDIR = _s.OUTDIR

DROPIN_DIR = "/etc/systemd/system/ov5678-camera.service.d"
DROPIN = os.path.join(DROPIN_DIR, "99-ccm-bracket.conf")
SUPERVISOR = "ov5678-ondemand.service"
CLIP = 248
EXPOSURE = os.environ.get("CCM_EXPOSURE", "2016")

# The white balance must be IDENTICAL for every rung of the ladder.
#
# Grey world re-adapts to each exposure, and a bracket shot that way cannot be
# merged: the rungs no longer share a colour scaling, only a brightness one.
# Measured, with the gains left automatic, white came back R/G 0.447 at gain 1.0
# against 1.0 at gain 8.0, and the merged fit was worse than a single exposure
# (mean error 0.071 against 0.041) despite using twice as many patches.
#
# The exact values matter much less than their constancy - any residual tint is
# neutralised on the merged data below - but they have to be pinned. These are
# the gains measured to neutralise this display; override for another target.
AWB_R = os.environ.get("CCM_AWB_R", "1.944")
AWB_B = os.environ.get("CCM_AWB_B", "1.700")


def set_gain(gain):
    os.makedirs(DROPIN_DIR, exist_ok=True)
    with open(DROPIN, "w") as f:
        f.write("[Service]\n"
                f"Environment=SOFTISP_EXPOSURE={EXPOSURE}\n"
                f"Environment=SOFTISP_GAIN={gain}\n"
                f"Environment=SOFTISP_AWB_R={AWB_R}\n"
                f"Environment=SOFTISP_AWB_B={AWB_B}\n")
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "restart", SUPERVISOR], check=True)
    wait_ready()


def wait_ready(timeout=40):
    """Block until the loopback actually yields frames.

    Restarting the supervisor leaves a window with no producer attached, and a
    consumer that arrives in it fails negotiation in milliseconds rather than
    waiting - v4l2loopback has no format until something is producing. A fixed
    sleep guessed wrong and lost the third rung of a four-rung ladder, so probe
    for frames instead of guessing.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(
            ["gst-launch-1.0", "-q", "v4l2src", "device=/dev/video0",
             "num-buffers=3", "!", "fakesink"],
            capture_output=True, timeout=25)
        if r.returncode == 0:
            time.sleep(1)
            return
        time.sleep(2)
    sys.exit("the loopback never produced frames - is something else holding it?")


def clear_gain():
    if os.path.exists(DROPIN):
        os.remove(DROPIN)
    try:
        os.rmdir(DROPIN_DIR)
    except OSError:
        pass
    subprocess.run(["systemctl", "daemon-reload"], check=False)
    subprocess.run(["systemctl", "restart", SUPERVISOR], check=False)


def shoot(gain):
    """One exposure of the ladder: returns (actual analogue gain, samples)."""
    set_gain(gain)
    img = capture()
    hr = exposure_headroom()
    if not hr:
        sys.exit("could not read the sensor controls - is the subdev present?")
    again = hr["analogue_gain"][2]
    e_val, e_max = hr["exposure"][2], hr["exposure"][1]
    if str(e_val) != str(EXPOSURE):
        print(f"  NOTE: asked for exposure {EXPOSURE}, sensor reports {e_val}"
              f" (max {e_max})")
    return again, sample(img), img


def installed_matrix():
    """The ccm currently in the tuning file, or None."""
    import re
    for y in ("/usr/local/share/libcamera/ipa/simple/ov5675.yaml",
              "/usr/share/libcamera/ipa/simple/ov5675.yaml"):
        if not os.path.exists(y):
            continue
        m = re.search(r"ccm:\s*\[([^\]]+)\]", open(y).read())
        if m:
            v = [float(x) for x in m.group(1).split(",")]
            if len(v) == 9:
                return [v[0:3], v[3:6], v[6:9]]
    return None


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root (the gain is set through a systemd drop-in)")

    ladder = sys.argv[1:] or ["1.0", "2.0", "4.0", "8.0"]
    print(f"bracketing over analogue gain: {', '.join(ladder)}")
    print(f"white balance pinned at R {AWB_R}  B {AWB_B} for every rung\n")

    shots = []
    try:
        for g in ladder:
            again, sampled, img = shoot(g)
            peaks = [pk for _c, pk in sampled]
            nclip = sum(1 for pk in peaks if pk >= CLIP)
            print(f"  gain {g:>5} -> sensor reports {again:4d}"
                  f" ({again / 128:.2f}x), {nclip} patch(es) clipped")
            shots.append((again, sampled, img))
    finally:
        clear_gain()

    if len(shots) < 2:
        sys.exit("need at least two exposures to bracket")

    # Brightest first: prefer the most exposed sample that has not clipped, so
    # every patch is read where its signal to noise is best.
    shots.sort(key=lambda s: -s[0])
    ref_again = shots[0][0]

    merged, chosen, lost = [], [], []
    for i in range(len(PATCHES)):
        for again, sampled, _img in shots:
            c, pk = sampled[i]
            if pk < CLIP:
                scale = ref_again / again
                merged.append([v * scale for v in c])
                chosen.append((again, pk))
                break
        else:
            # Clipped even at the lowest gain in the ladder.
            again, sampled, _img = shots[-1]
            c, _pk = sampled[i]
            merged.append([v * ref_again / again for v in c])
            chosen.append((again, 255))
            lost.append(PATCHES[i][0])

    ref = [[srgb_to_linear(v) for v in rgb] for _n, rgb in PATCHES]

    print(f"\n  {'patch':<15} {'read at':>9} {'peak':>5}   {'merged (linear)':>22}")
    for (name, _rgb), (again, pk), c in zip(PATCHES, chosen, merged):
        print(f"  {name:<15} {again / 128:8.2f}x {pk:5d}   "
              f"({c[0]:6.3f},{c[1]:6.3f},{c[2]:6.3f})")

    if lost:
        print(f"\n  WARNING: still clipped at the lowest gain: {', '.join(lost)}")
        print("  Extend the ladder downwards, or dim the target.")

    # Anchor the scale on white. The fit keeps neutrals neutral by construction,
    # so it cannot absorb an overall exposure error - the camera's white has to
    # sit where the target's white sits before fitting, or every row is biased.
    wh = merged[18]
    tw = sum(ref[18]) / 3
    cw = sum(wh) / 3
    if cw <= 0:
        sys.exit("white patch is black - check the alignment")
    merged = [[v * tw / cw for v in c] for c in merged]
    print(f"\n  normalised exposure by x{tw / cw:.3f} to put white on target")

    wh = merged[18]
    print(f"  white after: R/G {wh[0] / wh[1]:.3f}  B/G {wh[2] / wh[1]:.3f}")
    wb = [wh[1] / wh[0] if wh[0] > 1e-6 else 1.0, 1.0,
          wh[1] / wh[2] if wh[2] > 1e-6 else 1.0]
    if abs(wb[0] - 1) > 0.02 or abs(wb[2] - 1) > 0.02:
        print(f"  neutralising residual white balance: R x{wb[0]:.3f}  B x{wb[2]:.3f}")
        merged = [[c[0] * wb[0], c[1], c[2] * wb[2]] for c in merged]

    # Keep the merged samples. Scoring a candidate matrix afterwards should not
    # need another six minutes of captures, and a fit is only trustworthy if it
    # can be re-scored against the data it came from.
    import json
    data_path = os.path.join(OUTDIR, "ccm-bracket.json")
    with open(data_path, "w") as f:
        json.dump({"patches": [n for n, _ in PATCHES],
                   "camera_linear": merged, "target_linear": ref}, f, indent=1)
    print(f"  merged samples saved: {data_path}")

    m = solve(merged, ref)

    print("\nfitted matrix (camera RGB -> sRGB, linear, rows sum to 1):")
    for row in m:
        print("   " + "  ".join(f"{v:+8.4f}" for v in row))

    before = sum(sum(abs(c[k] - t[k]) for k in range(3))
                 for c, t in zip(merged, ref)) / (3 * len(ref))
    after = 0.0
    for c, t in zip(merged, ref):
        out = [sum(m[k][j] * c[j] for j in range(3)) for k in range(3)]
        after += sum(abs(out[k] - t[k]) for k in range(3))
    after /= 3 * len(ref)
    print(f"\n  fitted on all {len(merged)} patches")
    print(f"  mean abs error, linear:  before {before:.4f}   after {after:.4f}")

    dom = all(abs(m[k][k]) > abs(m[k][(k + 1) % 3]) and
              abs(m[k][k]) > abs(m[k][(k + 2) % 3]) for k in range(3))
    print("  diagonally dominant: " + ("yes" if dom else
          "NO - treat this result with suspicion"))

    # Score whatever is installed on the SAME data. A new matrix is only worth
    # installing if it beats the one already there on the same samples; the two
    # fits' own residuals are not comparable, because each was fitted on a
    # different set of patches.
    cur = installed_matrix()
    if cur:
        err = 0.0
        for c, t in zip(merged, ref):
            out = [sum(cur[k][j] * c[j] for j in range(3)) for k in range(3)]
            err += sum(abs(out[k] - t[k]) for k in range(3))
        err /= 3 * len(ref)
        print(f"\n  currently installed matrix, same data: {err:.4f}")
        print(f"  fitted here:                          {after:.4f}"
              f"   ({'better' if after < err else 'WORSE - do not install'})")

    flat = ", ".join(f"{v:.4f}" for row in m for v in row)
    print("\nadd to libcamera/ov5675.yaml, before the Adjust entry:\n")
    print("    - Ccm:\n        ccms:\n          - ct: 5000")
    print(f"            ccm: [ {flat} ]")


if __name__ == "__main__":
    main()
