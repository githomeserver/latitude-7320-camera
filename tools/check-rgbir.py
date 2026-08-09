#!/usr/bin/env python3
"""Test whether this sensor is a 2x2 Bayer or a 4x4 RGB-IR mosaic.

Intel's own pipeline configuration for this exact camera module says RGB-IR:

    graph_settings_OV5678_0BF501T3_TGL.xml
        sensor_name="OV5678" bayer_order="GIGI_RGBG_GIGI_BGRG"
        sensor_mode ... sensor_type="RGB_IR"

("0BF501T3" is the ACPI _DDN of the front camera on this machine, so it is
this module and not a near relative. The rear OV8856 in the same directory
says plain "GRBG", which is a useful control.)

That pattern is a 4x4 cell, one pixel in four being infrared:

        col 0  1  2  3
    row 0  G  I  G  I
    row 1  R  G  B  G
    row 2  G  I  G  I
    row 3  B  G  R  G

THE DECISIVE TEST

Read as a 2x2 Bayer - which is what ov5675.c declares - positions (1,0) and
(1,2) fall in the same channel, so they must agree on any scene whatsoever.
Under the 4x4 pattern (1,0) is RED and (1,2) is BLUE, so on a strongly
coloured scene they must diverge. Same for (1,0) vs (3,0), which would be R
vs B.

Equally, a 2x2 reading lumps (0,1) and (0,3) together; under the 4x4 pattern
both are IR, so those SHOULD agree - that is the control that shows a
divergence elsewhere is not just noise.

Point the camera at something strongly and unevenly coloured - a red or blue
object filling much of the frame is ideal. A white wall proves nothing here,
because on a neutral scene R and B read similarly anyway.

Run as root via check-rgbir.sh.
"""

import importlib.util
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "msd", os.path.join(HERE, "measure-sensor-delays.py"))
msd = importlib.util.module_from_spec(spec)
sys.modules["msd"] = msd
spec.loader.exec_module(msd)

# Intel's declared pattern, row-major.
PATTERN = [
    ["G", "I", "G", "I"],
    ["R", "G", "B", "G"],
    ["G", "I", "G", "I"],
    ["B", "G", "R", "G"],
]


def means16(cap, rows=180, cols=240, centre=0.7):
    """Mean of each of the 16 positions in the 4x4 cell.

    Steps and origin are kept multiples of 4 so the cell phase holds; getting
    this wrong relabels every position and the test becomes meaningless.
    Sampling is restricted to the middle of the frame because the lens
    vignettes ~31% into the corners.
    """
    import fcntl
    b = msd.Buffer(type=msd.BUF_TYPE_VIDEO_CAPTURE, memory=msd.MEMORY_MMAP)
    fcntl.ioctl(cap.fd, msd.VIDIOC_DQBUF, b)
    mv = cap.maps[b.index]
    stride = cap.stride
    sums = [0] * 16
    count = 0
    ystep = max(4, (cap.h // rows) & ~3)
    xstep = max(4, (cap.w // cols) & ~3)
    y0 = int(cap.h * (1 - centre) / 2) & ~3
    x0 = int(cap.w * (1 - centre) / 2) & ~3
    for y in range(y0, cap.h - y0 - 3, ystep):
        for x in range(x0, cap.w - x0 - 3, xstep):
            for dy in range(4):
                base = (y + dy) * stride
                for dx in range(4):
                    o = base + (x + dx) * 2
                    sums[dy * 4 + dx] += mv[o] | (mv[o + 1] << 8)
            count += 1
    fcntl.ioctl(cap.fd, msd.VIDIOC_QBUF, b)
    return [s / count for s in sums]


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root")

    graph = msd.parse_graph()
    found = msd.locate(graph)
    if not found:
        sys.exit("could not locate the sensor path")
    sname, csi, cpad, cap_ent, node, fmt = found
    subdev = graph[sname]["node"]
    print(f"sensor   {sname}  {subdev}")
    print(f"capture  {node}")

    # MUST be the full-resolution mode. The 1296x972 mode is 2x2 binned, and
    # binning collapses a 4x4 RGB-IR cell into something Bayer-shaped - the
    # four IR pixels get averaged in with colour pixels and the structure this
    # test looks for is destroyed before it reaches us. Intel's graph settings
    # list exactly one mode for this sensor, 2592x1944, and several for the
    # plain-Bayer OV8856 alongside it; that asymmetry is the tell.
    fmt = (fmt[0], 2592, 1944)
    msd.setup_pipeline(sname, csi, cpad, cap_ent, fmt)

    cap = msd.Capture(node, want=(fmt[1], fmt[2]))
    if (cap.w, cap.h) != (2592, 1944):
        sys.exit(f"ERROR: got {cap.w}x{cap.h}, need 2592x1944 (unbinned).\n"
                 "A binned frame cannot answer this question.")
    print(f"format   {cap.w}x{cap.h} {cap.fourcc} stride={cap.stride}")
    print(f"declared {fmt[0]}\n")

    ctrls = msd.Ctrls(subdev)
    emin, emax = msd.ctrl_range(subdev, "exposure")
    gmin, gmax = msd.ctrl_range(subdev, "analogue_gain")
    cap.start()
    try:
        # Dark frame first: without subtracting the pedestal every position is
        # dominated by a common offset and they all look alike.
        ctrls.set(msd.CID_ANALOGUE_GAIN, gmin)
        ctrls.set(msd.CID_EXPOSURE, emin)
        for _ in range(20):
            cap.frame()
        black = [statistics.mean(v) for v in
                 zip(*(means16(cap) for _ in range(3)))]

        # Then expose so the greens sit mid-range. Ramp exposure first and only
        # then gain: an earlier version pinned gain at minimum, never reached a
        # usable level, and still printed a verdict off a 3-count signal - where
        # every position agrees because it is all noise floor.
        exposure = max(emin, emax // 3)
        gain = gmin
        g = 0.0
        for _ in range(16):
            ctrls.set(msd.CID_EXPOSURE, exposure)
            ctrls.set(msd.CID_ANALOGUE_GAIN, gain)
            for _ in range(12):
                cap.frame()
            m = means16(cap)
            g = statistics.mean(m[i * 4 + j] - black[i * 4 + j]
                                for i in range(4) for j in range(4)
                                if PATTERN[i][j] == "G")
            print(f"  exposure {exposure:6d}  gain {gain:5d}  -> green {g:7.1f}")
            if 120 < g < 600:
                break
            # Cap the step. Jumping straight to the maximum overshoots the
            # target window and then has to walk back; a known-good working
            # point on this sensor is exposure 2016 with gain ~1024.
            want = min(4.0, max(0.25, 300 / max(g, 0.5)))
            if g < 120:
                if exposure < emax:
                    exposure = min(emax, max(exposure + 1, int(exposure * want)))
                elif gain < gmax:
                    gain = min(gmax, max(gain + 1, int(max(gain, 1) * want)))
                else:
                    break                      # nothing left to give
            else:
                if gain > gmin:
                    gain = max(gmin, int(gain * want))
                else:
                    exposure = max(emin + 1, int(exposure * want))
        lit = [statistics.mean(v) for v in
               zip(*(means16(cap) for _ in range(5)))]
    finally:
        cap.stop()

    sig = [lit[i] - black[i] for i in range(16)]

    # Fail closed. Below this the positions agree because there is no signal,
    # not because the mosaic is uniform, and the verdict would be meaningless.
    gsig = statistics.mean(sig[i * 4 + j] for i in range(4) for j in range(4)
                           if PATTERN[i][j] == "G")
    if gsig < 60:
        print(f"\ngreen signal only {gsig:.1f} counts above black - too dark to "
              f"conclude anything.\nAdd light or point at a brighter subject. "
              f"NO VERDICT.")
        sys.exit(2)

    print("black-level-corrected mean per position (10-bit counts)\n")
    print("        col 0     col 1     col 2     col 3")
    for i in range(4):
        row = "  ".join(f"{PATTERN[i][j]} {sig[i*4+j]:7.1f}" for j in range(4))
        print(f"  row {i}  {row}")

    def pos(i, j):
        return sig[i * 4 + j]

    def rel(a, b):
        return abs(a - b) / max(a, b, 1e-9) * 100

    print("\n" + "=" * 66)
    print("DECISIVE: positions a 2x2 Bayer says are the SAME channel")
    print("=" * 66)
    tests = [
        ("(1,0) vs (1,2)", pos(1, 0), pos(1, 2), "R vs B under RGB-IR"),
        ("(1,0) vs (3,0)", pos(1, 0), pos(3, 0), "R vs B under RGB-IR"),
        ("(3,0) vs (3,2)", pos(3, 0), pos(3, 2), "B vs R under RGB-IR"),
    ]
    worst = 0.0
    for name, a, b, why in tests:
        d = rel(a, b)
        worst = max(worst, d)
        print(f"  {name}  {a:7.1f} vs {b:7.1f}   differ {d:5.1f}%   ({why})")

    print("\nCONTROL: positions RGB-IR says are the same (both IR)")
    ctl = [("(0,1) vs (0,3)", pos(0, 1), pos(0, 3)),
           ("(0,1) vs (2,1)", pos(0, 1), pos(2, 1))]
    ctlworst = 0.0
    for name, a, b in ctl:
        d = rel(a, b)
        ctlworst = max(ctlworst, d)
        print(f"  {name}  {a:7.1f} vs {b:7.1f}   differ {d:5.1f}%")

    print("\nGROUPED under Intel's GIGI_RGBG_GIGI_BGRG:")
    for ch in "GIRB":
        vs = [pos(i, j) for i in range(4) for j in range(4)
              if PATTERN[i][j] == ch]
        print(f"  {ch}  n={len(vs)}  mean {statistics.mean(vs):7.1f}"
              f"   spread {max(vs)-min(vs):6.1f}")

    print("\n" + "=" * 66)
    if worst > 15 and worst > ctlworst * 2:
        print(f"VERDICT: RGB-IR CONFIRMED. Positions the 2x2 model calls one")
        print(f"channel differ by {worst:.1f}%, while the IR control pair agrees")
        print(f"to {ctlworst:.1f}%. A 2x2 Bayer cannot produce that.")
    elif worst < 8:
        print(f"VERDICT: consistent with plain 2x2 Bayer ({worst:.1f}% spread).")
        print("Intel's config says otherwise - re-run on a MORE COLOURED scene")
        print("before believing this; a neutral scene cannot separate R from B.")
    else:
        print(f"VERDICT: inconclusive. {worst:.1f}% vs {ctlworst:.1f}% control.")
        print("Use a scene with a large strongly saturated region.")
    print("=" * 66)


if __name__ == "__main__":
    main()
