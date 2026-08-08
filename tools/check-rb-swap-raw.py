#!/usr/bin/env python3
"""Decide the CFA phase from raw Bayer, with AGC and AWB out of the picture.

Testing through the processed output failed: the AGC blows a single primary up
until it clips, and the AWB applies a 6x red gain on top, so both channels come
back near-white. Raw Bayer at a fixed exposure has neither.

Show a saturated primary fullscreen and see which CFA position responds:

  GRBG (what ov5675.c declares)   GBRG (the alternative)
    (0,0)=Gr  (0,1)=R               (0,0)=Gb  (0,1)=B
    (1,0)=B   (1,1)=Gb              (1,0)=R   (1,1)=Gr

Under red light (0,1) should dominate for GRBG, (1,0) for GBRG. The two green
positions agree in both, which is why the earlier check could not tell them
apart.

Run as root via check-rb-swap-raw.sh.
"""
import importlib.util, os, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("msd", os.path.join(HERE, "measure-sensor-delays.py"))
msd = importlib.util.module_from_spec(spec); sys.modules["msd"] = msd
spec.loader.exec_module(spec and msd)
cbo = importlib.util.spec_from_file_location("cbo", os.path.join(HERE, "check-bayer-order.py"))
_c = importlib.util.module_from_spec(cbo); sys.modules["cbo"] = _c
cbo.loader.exec_module(_c)

def main():
    if os.geteuid() != 0:
        sys.exit("must run as root")
    label = sys.argv[1] if len(sys.argv) > 1 else "?"

    g = msd.parse_graph(); found = msd.locate(g)
    if not found:
        sys.exit("could not locate the sensor path")
    sname, csi, cpad, cap_ent, node, fmt = found
    subdev = g[sname]["node"]
    msd.setup_pipeline(sname, csi, cpad, cap_ent, fmt)
    cap = msd.Capture(node, want=(fmt[1], fmt[2]))
    ctrls = msd.Ctrls(subdev)
    emin, emax = msd.ctrl_range(subdev, "exposure")
    gmin, gmax = msd.ctrl_range(subdev, "analogue_gain")

    cap.start()
    try:
        # Fixed exposure and gain: no AGC, no AWB, nothing adaptive.
        ctrls.set(msd.CID_ANALOGUE_GAIN, gmin)
        ctrls.set(msd.CID_EXPOSURE, emin)
        for _ in range(20):
            cap.frame()
        black = [statistics.mean(s[i] for s in (_c.cfa_means(cap, centre=0.5) for _ in range(3)))
                 for i in range(4)]
        # Ramp exposure then gain until there is real signal. A screen-only
        # scene in a dark room is far dimmer than a lit room, and the previous
        # fixed minimum-gain setting returned pure noise (under 2 counts).
        exposure, gain = max(emin, emax // 2), gmin
        raw = None
        for _ in range(12):
            ctrls.set(msd.CID_EXPOSURE, exposure)
            ctrls.set(msd.CID_ANALOGUE_GAIN, gain)
            for _ in range(15):
                cap.frame()
            raw = [statistics.mean(s[i] for s in (_c.cfa_means(cap, centre=0.5) for _ in range(3)))
                   for i in range(4)]
            peak = max(raw[i] - black[i] for i in range(4))
            if peak > 150:
                break
            if exposure < emax:
                exposure = min(emax, int(exposure * 2))
            elif gain < gmax:
                gain = min(gmax, int(gain * 2))
            else:
                break
        print(f"  exposure={exposure} gain={gain}  peak signal {peak:.1f} counts")
        if peak < 20:
            print("  *** almost no light reaching the sensor. Is the screen on,")
            print("      awake, at full brightness, and actually filling the frame?")
    finally:
        cap.stop(); ctrls.close(); cap.close()

    # Save a crude preview so framing can be checked. Raw Bayer has no colour
    # without demosaic, but the green positions alone give a usable luminance
    # image - enough to see whether the screen actually fills the frame.
    try:
        from PIL import Image
        import fcntl
        b = msd.Buffer(type=msd.BUF_TYPE_VIDEO_CAPTURE, memory=msd.MEMORY_MMAP)
        cap2 = msd.Capture(node, want=(fmt[1], fmt[2]))
        cap2.start()
        for _ in range(4):
            cap2.frame()
        fcntl.ioctl(cap2.fd, msd.VIDIOC_DQBUF, b)
        mv = cap2.maps[b.index]
        W, H, st = cap2.w // 2, cap2.h // 2, cap2.stride
        pk = max(1.0, max(raw[i] - black[i] for i in range(4)))
        pscale = 200.0 / pk        # stretch so the brightest patch is visible
        im = Image.new("L", (W, H))
        pxs = im.load()
        for y in range(H):
            o = (y * 2) * st
            for x in range(W):
                v = mv[o + x * 4] | (mv[o + x * 4 + 1] << 8)
                pxs[x, y] = min(255, max(0, int((v - 64) * pscale)))
        prev = os.path.join(HERE, "..", "data", f"rbtest-{label}.png")
        im.save(prev)
        fcntl.ioctl(cap2.fd, msd.VIDIOC_QBUF, b)
        cap2.stop(); cap2.close()
        print(f"  framing preview: {prev}")
    except Exception as e:
        print(f"  (preview failed: {e})")

    m = [max(raw[i] - black[i], 0.0) for i in range(4)]
    names = ["(0,0)", "(0,1)", "(1,0)", "(1,1)"]
    print(f"\n  displaying: {label}")
    print(f"  black level: " + " ".join(f"{v:.1f}" for v in black))
    print("  signal above black:")
    for n, v in zip(names, m):
        print(f"    {n}  {v:8.1f}")
    if max(m) > 900:
        print("    *** saturated - lower the screen brightness and retry")
    greens = (m[0] + m[3]) / 2
    print(f"\n  greens (0,0)/(1,1) avg {greens:.1f}")
    print(f"  (0,1) = R if GRBG, B if GBRG : {m[1]:.1f}")
    print(f"  (1,0) = B if GRBG, R if GBRG : {m[2]:.1f}")
    if m[1] > m[2] * 1.3:
        print(f"\n  => (0,1) dominates. Under {label} light that means (0,1) is the {label} filter.")
    elif m[2] > m[1] * 1.3:
        print(f"\n  => (1,0) dominates. Under {label} light that means (1,0) is the {label} filter.")
    else:
        print("\n  => no clear winner; try a brighter/more saturated screen")

main()
