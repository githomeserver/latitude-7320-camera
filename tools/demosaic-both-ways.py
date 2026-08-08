#!/usr/bin/env python3
"""Settle the CFA phase by demosaicing one raw frame both ways and looking.

Every previous attempt fought the lighting: an object close enough to fill the
frame shades itself, a screen is too dim, and the processed output is
neutralised by grey-world AWB. This needs none of that - one well-exposed raw
frame of any colourful scene, demosaiced twice, and the eye decides.

  GRBG (declared)          GBRG (alternative)
    (0,0)=Gr  (0,1)=R        (0,0)=Gb  (0,1)=B
    (1,0)=B   (1,1)=Gb       (1,0)=R   (1,1)=Gr

Each output is independently grey-world balanced, so both look neutral overall
and the only difference is where the hues land. One will show your scene in
its real colours; the other will have red and blue transposed.

Run as root via demosaic-both-ways.sh. Point at something colourful and
well-lit - it does NOT need to fill the frame.
"""
import importlib.util, os, statistics, sys, fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
def _load(n, f):
    sp = importlib.util.spec_from_file_location(n, os.path.join(HERE, f))
    m = importlib.util.module_from_spec(sp); sys.modules[n] = m; sp.loader.exec_module(m)
    return m
msd = _load("msd", "measure-sensor-delays.py")
_c  = _load("cbo", "check-bayer-order.py")

from PIL import Image


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root")
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
        ctrls.set(msd.CID_ANALOGUE_GAIN, gmin); ctrls.set(msd.CID_EXPOSURE, emin)
        for _ in range(20): cap.frame()
        black = statistics.mean(_c.cfa_means(cap))

        exposure, gain = max(emin, emax // 4), gmin
        for _ in range(12):
            ctrls.set(msd.CID_EXPOSURE, exposure); ctrls.set(msd.CID_ANALOGUE_GAIN, gain)
            for _ in range(15): cap.frame()
            peak = max(_c.cfa_means(cap, centre=0.5)) - black
            if peak > 250: break
            if exposure < emax: exposure = min(emax, int(exposure * 2))
            elif gain < gmax:   gain = min(gmax, int(gain * 2))
            else: break
        print(f"  exposure={exposure} gain={gain}  peak {peak:.0f} counts above black")
        if peak < 80:
            print("  *** dim - the result may be noisy; more light would help")

        b = msd.Buffer(type=msd.BUF_TYPE_VIDEO_CAPTURE, memory=msd.MEMORY_MMAP)
        fcntl.ioctl(cap.fd, msd.VIDIOC_DQBUF, b)
        mv = bytes(cap.maps[b.index][:cap.stride * cap.h])
        fcntl.ioctl(cap.fd, msd.VIDIOC_QBUF, b)
    finally:
        cap.stop(); ctrls.close(); cap.close()

    W, H, st = cap.w // 2, cap.h // 2, cap.stride
    # Pull the four CFA positions out once; the two orderings just relabel them.
    p00 = [[0]*W for _ in range(H)]; p01 = [[0]*W for _ in range(H)]
    p10 = [[0]*W for _ in range(H)]; p11 = [[0]*W for _ in range(H)]
    for y in range(H):
        r0 = (2*y) * st; r1 = (2*y + 1) * st
        for x in range(W):
            o = x * 4
            p00[y][x] = max(0, (mv[r0+o]   | (mv[r0+o+1] << 8)) - black)
            p01[y][x] = max(0, (mv[r0+o+2] | (mv[r0+o+3] << 8)) - black)
            p10[y][x] = max(0, (mv[r1+o]   | (mv[r1+o+1] << 8)) - black)
            p11[y][x] = max(0, (mv[r1+o+2] | (mv[r1+o+3] << 8)) - black)

    for name, Rp, Bp in (("grbg", p01, p10), ("gbrg", p10, p01)):
        # grey-world per hypothesis, so both are neutral and only hue differs
        sr = sum(map(sum, Rp)); sg = sum(map(sum, p00)) + sum(map(sum, p11))
        sb = sum(map(sum, Bp))
        sg /= 2
        kr = sg / max(sr, 1); kb = sg / max(sb, 1)
        peak95 = max(1.0, sg / (W * H) * 4)
        im = Image.new("RGB", (W, H)); px = im.load()
        for y in range(H):
            for x in range(W):
                gg = (p00[y][x] + p11[y][x]) / 2
                vals = (Rp[y][x] * kr, gg, Bp[y][x] * kb)
                px[x, y] = tuple(
                    min(255, int(255 * ((v / peak95) ** (1 / 2.2)))) for v in vals)
        out = os.path.join(HERE, "..", "data", f"demosaic-{name}.png")
        im.save(out)
        print(f"  wrote {out}")

    print("\n  Open both. Whichever shows your scene in its real colours is the")
    print("  true CFA phase. ov5675.c declares GRBG.")

main()
