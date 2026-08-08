#!/usr/bin/env python3
"""Check the sensor's actual Bayer phase, and its native channel balance.

Why: the processed output has a fixed green cast - R/G 0.735, B/G 0.943 -
that does not drift at all across frames. A working grey-world AWB should pull
those toward 1.0, so either AWB is not correcting, or it is correcting the
wrong channels because the declared Bayer order does not match the sensor's
actual phase.

ov5675.c hardcodes MEDIA_BUS_FMT_SGRBG10_1X10 for every mode, i.e. GRBG:

    (0,0)=Gr  (0,1)=R
    (1,0)=B   (1,1)=Gb

Both green positions carry the same colour filter, so their means must agree
closely whatever the scene is. If instead the *other* diagonal pair matches,
the phase is shifted and R and B are swapped - which no amount of AWB can fix
and which looks exactly like an uncorrectable cast.

Point the camera at a flat, evenly lit surface. Run as root via
check-bayer-order.sh.
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


def cfa_means(cap, rows=240, cols=320, centre=1.0):
    """Mean of each of the four CFA positions, from the raw 16-bit buffer.

    centre < 1.0 restricts sampling to that fraction of the frame around the
    middle. The lens vignettes hard - the corners are close to black - so on a
    dim scene the edges contribute mostly noise and drag the signal down.
    Ratios between positions are unaffected either way, since all four are
    interleaved across the same area, but the SNR is much better in the middle.
    """
    import fcntl
    b = msd.Buffer(type=msd.BUF_TYPE_VIDEO_CAPTURE, memory=msd.MEMORY_MMAP)
    fcntl.ioctl(cap.fd, msd.VIDIOC_DQBUF, b)
    mv = cap.maps[b.index]
    stride = cap.stride
    sums = [0, 0, 0, 0]
    counts = [0, 0, 0, 0]
    ystep = max(2, (cap.h // rows) & ~1)     # keep steps even so the phase holds
    xstep = max(2, (cap.w // cols) & ~1)
    # Keep the origin even too, or the CFA phase shifts and the four positions
    # get relabelled.
    y0 = (int(cap.h * (1 - centre) / 2)) & ~1
    x0 = (int(cap.w * (1 - centre) / 2)) & ~1
    y1 = cap.h - y0
    x1 = cap.w - x0
    for y in range(y0, y1 - 1, ystep):
        base0 = y * stride
        base1 = (y + 1) * stride
        for x in range(x0, x1 - 1, xstep):
            o0 = base0 + x * 2
            o1 = base1 + x * 2
            # little-endian u16, 10 bits significant
            sums[0] += mv[o0] | (mv[o0 + 1] << 8)
            sums[1] += mv[o0 + 2] | (mv[o0 + 3] << 8)
            sums[2] += mv[o1] | (mv[o1 + 1] << 8)
            sums[3] += mv[o1 + 2] | (mv[o1 + 3] << 8)
            for i in range(4):
                counts[i] += 1
    fcntl.ioctl(cap.fd, msd.VIDIOC_QBUF, b)
    return [s / c for s, c in zip(sums, counts)]


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
    msd.setup_pipeline(sname, csi, cpad, cap_ent, fmt)

    cap = msd.Capture(node, want=(fmt[1], fmt[2]))
    print(f"format   {cap.w}x{cap.h} {cap.fourcc} stride={cap.stride}")
    print(f"declared {fmt[0]}  -> (0,0)=Gr (0,1)=R (1,0)=B (1,1)=Gb\n")

    ctrls = msd.Ctrls(subdev)
    emin, emax = msd.ctrl_range(subdev, "exposure")
    gmin, gmax = msd.ctrl_range(subdev, "analogue_gain")
    cap.start()
    try:
        # Black level first. At minimum exposure the frame is essentially dark,
        # so what is left is the pedestal. Without subtracting it the channel
        # ratios are dominated by an offset common to all four positions and
        # come out far closer to 1.0 than the real signal ratios.
        ctrls.set(msd.CID_ANALOGUE_GAIN, gmin)
        ctrls.set(msd.CID_EXPOSURE, emin)
        for _ in range(20):
            cap.frame()
        black = [statistics.mean(s[i] for s in (cfa_means(cap) for _ in range(3)))
                 for i in range(4)]

        # Then a properly exposed frame. Walk exposure up until the greens sit
        # in a sensible part of the range rather than hugging the pedestal.
        exposure = max(emin, emax // 3)
        gain = gmin
        green = 0.0
        for _ in range(12):
            ctrls.set(msd.CID_EXPOSURE, exposure)
            ctrls.set(msd.CID_ANALOGUE_GAIN, gain)
            for _ in range(12):
                cap.frame()
            probe = cfa_means(cap)
            green = (probe[0] + probe[3]) / 2 - (black[0] + black[3]) / 2
            if green > 200:
                break
            # Exposure first, then gain. Gain was previously left pinned at the
            # minimum from the black-level step, so a dim scene stayed dim.
            if exposure < emax:
                exposure = min(emax, int(exposure * 2))
            elif gain < gmax:
                gain = min(gmax, int(gain * 2))
            else:
                break
        print(f"black level (exposure={emin}): "
              + "  ".join(f"{v:.1f}" for v in black))
        print(f"signal      (exposure={exposure} gain={gain}): "
              f"green above black = {green:.1f}")
        if green < 60:
            print("  *** TOO DARK - under ~60 counts the red channel is mostly")
            print("      noise and the ratios below are not trustworthy. Use a")
            print("      brighter, well-lit white surface and re-run.")
        print()
        samples = [cfa_means(cap) for _ in range(5)]
    finally:
        cap.stop()
        ctrls.close()
        cap.close()

    raw = [statistics.mean(s[i] for s in samples) for i in range(4)]
    m = [max(raw[i] - black[i], 0.1) for i in range(4)]
    print("raw CFA means before black-level subtraction:")
    print("  " + "  ".join(f"{v:8.1f}" for v in raw))
    print()
    labels = ["(0,0)", "(0,1)", "(1,0)", "(1,1)"]
    print("black-level-corrected CFA means (10-bit):")
    for lab, v in zip(labels, m):
        print(f"  {lab}  {v:8.1f}")

    d1 = abs(m[0] - m[3]) / max(m[0], m[3], 1) * 100     # declared green pair
    d2 = abs(m[1] - m[2]) / max(m[1], m[2], 1) * 100     # the other diagonal
    print(f"\n  diagonal (0,0)/(1,1) differ by {d1:5.1f}%   <- should be the greens")
    print(f"  diagonal (0,1)/(1,0) differ by {d2:5.1f}%")

    if d1 < d2:
        print("\n  => matches the declared GRBG phase; Bayer order is correct.")
        gr, r, b, gb = m
        g = (gr + gb) / 2
        print(f"     native balance: R/G {r / g:.3f}  B/G {b / g:.3f}")
        print("     AWB has to correct these to ~1.0; if the output still")
        print("     shows the same ratios, AWB is not being applied.")
    else:
        print("\n  => DOES NOT match GRBG. The green pair is the other diagonal,")
        print("     so the real phase is shifted and R/B are swapped. That is a")
        print("     driver/format bug, not a tuning problem.")


if __name__ == "__main__":
    main()
