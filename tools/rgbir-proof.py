#!/usr/bin/env python3
"""Demosaic one full-resolution raw frame as RGB-IR, and as the 2x2 Bayer the
pipeline currently assumes, from the SAME pixels. Side by side.

This is a demonstration, not a pipeline. It answers one question: how much
colour is this sensor actually delivering that we are currently throwing away?

Each 4x4 cell collapses to one output pixel, so the result is 648x486. That is
deliberate - it needs no interpolation at all, so nothing in the comparison
depends on the quality of a demosaic algorithm, only on which pixels are
assigned to which channel. Both panels get identical black level subtraction,
identical grey-world white balance and identical gamma, so the only difference
between them is the channel mapping.

    RGB-IR (Intel's GIGI_RGBG_GIGI_BGRG)   2x2 GBRG (what ov5675.c declares)
      R = mean of the 2 R positions          R = the 4 R-and-B positions mixed
      G = mean of the 8 G positions          G = the same 8 G positions
      B = mean of the 2 B positions          B = the 4 IR positions
      I = mean of the 4 IR positions

Run as root via rgbir-proof.sh.
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

from PIL import Image                                            # noqa: E402

PATTERN = [
    ["G", "I", "G", "I"],
    ["R", "G", "B", "G"],
    ["G", "I", "G", "I"],
    ["B", "G", "R", "G"],
]
IDX = {c: [i * 4 + j for i in range(4) for j in range(4) if PATTERN[i][j] == c]
       for c in "GIRB"}
# What a 2x2 GBRG reader lands on: (0,0)=G (0,1)=B (1,0)=R (1,1)=G, tiled.
BAYER_G = [i * 4 + j for i in range(4) for j in range(4) if (i + j) % 2 == 0]
BAYER_B = [i * 4 + j for i in range(4) for j in range(4)
           if i % 2 == 0 and j % 2 == 1]
BAYER_R = [i * 4 + j for i in range(4) for j in range(4)
           if i % 2 == 1 and j % 2 == 0]


def cells(cap, black, dump=None):
    """Yield (rgbi, bayer_rgb) per 4x4 cell, black-level corrected.

    Both tuples come from the same 16 pixels; only the grouping differs.
    If dump is given, the raw buffer is written there first so that other
    hypotheses - a different mosaic phase, R/B swapped, IR subtraction - can be
    tested offline without asking for another capture.
    """
    import fcntl
    b = msd.Buffer(type=msd.BUF_TYPE_VIDEO_CAPTURE, memory=msd.MEMORY_MMAP)
    fcntl.ioctl(cap.fd, msd.VIDIOC_DQBUF, b)
    mv = cap.maps[b.index]
    if dump:
        with open(dump, "wb") as fh:
            fh.write(mv[:cap.stride * cap.h])
        with open(dump + ".txt", "w") as fh:
            fh.write(f"{cap.w} {cap.h} {cap.stride} {cap.fourcc}\n"
                     f"black {' '.join(str(v) for v in black)}\n")
        print(f"  raw saved to {dump} ({cap.stride * cap.h} bytes)")
    stride = cap.stride
    W, H = cap.w // 4, cap.h // 4
    px = [0] * 16
    try:
        for cy in range(H):
            rows = [(cy * 4 + dy) * stride for dy in range(4)]
            for cx in range(W):
                x2 = cx * 8                   # 4 pixels, 2 bytes each
                k = 0
                for base in rows:
                    o = base + x2
                    for _ in range(4):
                        px[k] = (mv[o] | (mv[o + 1] << 8)) - black[k]
                        o += 2
                        k += 1
                yield ((sum(px[i] for i in IDX["R"]) / 2.0,
                        sum(px[i] for i in IDX["G"]) / 8.0,
                        sum(px[i] for i in IDX["B"]) / 2.0,
                        sum(px[i] for i in IDX["I"]) / 4.0),
                       (sum(px[i] for i in BAYER_R) / 4.0,
                        sum(px[i] for i in BAYER_G) / 8.0,
                        sum(px[i] for i in BAYER_B) / 4.0))
    finally:
        fcntl.ioctl(cap.fd, msd.VIDIOC_QBUF, b)


def encode(planes, w, h, ir_sub=0.0):
    """Grey-world white balance, then gamma 2.2. Identical for both panels."""
    n = len(planes)
    if ir_sub:
        planes = [(r - ir_sub * i, g - ir_sub * i, b - ir_sub * i, i)
                  for r, g, b, i in planes]
    sr = sum(max(p[0], 0.0) for p in planes) / n
    sg = sum(max(p[1], 0.0) for p in planes) / n
    sb = sum(max(p[2], 0.0) for p in planes) / n
    gr = sg / max(sr, 1e-6)
    gb = sg / max(sb, 1e-6)
    # Scale so the 99th percentile green hits near white, rather than the max,
    # so one hot pixel cannot darken the whole frame.
    gs = sorted(max(p[1], 0.0) for p in planes)
    ref = max(gs[int(n * 0.99)], 1e-6)
    out = bytearray(n * 3)
    inv = 1.0 / 2.2
    for k, p in enumerate(planes):
        v = (max(p[0], 0.0) * gr / ref, max(p[1], 0.0) / ref,
             max(p[2], 0.0) * gb / ref)
        out[k * 3 + 0] = min(255, round(min(v[0], 1.0) ** inv * 255))
        out[k * 3 + 1] = min(255, round(min(v[1], 1.0) ** inv * 255))
        out[k * 3 + 2] = min(255, round(min(v[2], 1.0) ** inv * 255))
    return Image.frombytes("RGB", (w, h), bytes(out))


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root")
    ir_sub = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0

    graph = msd.parse_graph()
    found = msd.locate(graph)
    if not found:
        sys.exit("could not locate the sensor path")
    sname, csi, cpad, cap_ent, node, fmt = found
    subdev = graph[sname]["node"]
    fmt = (fmt[0], 2592, 1944)
    msd.setup_pipeline(sname, csi, cpad, cap_ent, fmt)
    pf = {"SGRBG10_1X10": "BA10", "SGBRG10_1X10": "GB10",
          "SBGGR10_1X10": "BG10", "SRGGB10_1X10": "RG10"}[fmt[0]]
    cap = msd.Capture(node, want=(fmt[1], fmt[2]), pixfmt=pf)
    if (cap.w, cap.h) != (2592, 1944) or cap.fourcc != pf:
        sys.exit(f"need 2592x1944 {pf}, got {cap.w}x{cap.h} {cap.fourcc}")
    print(f"capture  {cap.w}x{cap.h} {cap.fourcc}")

    ctrls = msd.Ctrls(subdev)
    gmin, gmax = msd.ctrl_range(subdev, "analogue_gain")

    # Lengthen the frame before reading the exposure range. The ceiling is set
    # by the frame length, and the first run of this pinned BOTH exposure and
    # gain at maximum for only 11% of full scale - a noise-dominated frame with
    # almost no colour discrimination left to recover. Frame rate is irrelevant
    # for a single still, so trade it for light.
    vmin, vmax = msd.ctrl_range(subdev, "vertical_blanking")
    if vmax:
        want_v = min(vmax, 6000)
        ctrls.set(msd.CID_VBLANK, want_v)
        print(f"vblank   {want_v} (range {vmin}..{vmax}) to extend exposure")
    emin, emax = msd.ctrl_range(subdev, "exposure")
    print(f"exposure range now {emin}..{emax}")
    cap.start()
    try:
        ctrls.set(msd.CID_ANALOGUE_GAIN, gmin)
        ctrls.set(msd.CID_EXPOSURE, emin)
        for _ in range(20):
            cap.frame()
        black = [round(statistics.mean(v))
                 for v in zip(*(_flat16(cap) for _ in range(3)))]
        print(f"black    per-position {min(black)}..{max(black)}")

        exposure, gain = max(emin, emax // 3), gmin
        for _ in range(16):
            ctrls.set(msd.CID_EXPOSURE, exposure)
            ctrls.set(msd.CID_ANALOGUE_GAIN, gain)
            for _ in range(12):
                cap.frame()
            m = _flat16(cap)
            g = statistics.mean(m[i] - black[i] for i in IDX["G"])
            print(f"  exposure {exposure:6d} gain {gain:5d} -> green {g:7.1f}")
            if 120 < g < 600:
                break
            want = min(4.0, max(0.25, 300 / max(g, 0.5)))
            if g < 120:
                if exposure < emax:
                    exposure = min(emax, max(exposure + 1, int(exposure * want)))
                elif gain < gmax:
                    gain = min(gmax, max(gain + 1, int(max(gain, 1) * want)))
                else:
                    break
            else:
                if gain > gmin:
                    gain = max(gmin, int(gain * want))
                else:
                    exposure = max(emin + 1, int(exposure * want))
        if g < 60:
            sys.exit(f"\ngreen only {g:.1f} counts - too dark. Add light.")

        print("\ndemosaicing (pure python over 315k cells, ~20s)...")
        W, H = cap.w // 4, cap.h // 4
        rgbir_px, bayer_px = [], []
        for a, bpx in cells(cap, black, dump="/tmp/rgbir-raw.bin"):
            rgbir_px.append(a)
            bayer_px.append(bpx + (a[3],))
    finally:
        cap.stop()

    a = encode(rgbir_px, W, H, ir_sub)
    b = encode(bayer_px, W, H, 0.0)
    out = Image.new("RGB", (W * 2 + 12, H), (20, 20, 20))
    out.paste(b, (0, 0))
    out.paste(a, (W + 12, 0))
    dest = "/tmp/rgbir-proof.png"
    out.save(dest)
    b.save("/tmp/rgbir-asnow.png")
    a.save("/tmp/rgbir-fixed.png")
    print(f"\nwrote {dest}")
    print("  LEFT  = 2x2 GBRG, what the pipeline does now")
    print(f"  RIGHT = RGB-IR channel assignment"
          f"{f', IR subtracted x{ir_sub}' if ir_sub else ''}")


def _flat16(cap):
    """Mean of each of the 16 cell positions across the frame centre."""
    import fcntl
    b = msd.Buffer(type=msd.BUF_TYPE_VIDEO_CAPTURE, memory=msd.MEMORY_MMAP)
    fcntl.ioctl(cap.fd, msd.VIDIOC_DQBUF, b)
    mv = cap.maps[b.index]
    stride = cap.stride
    sums = [0] * 16
    cnt = 0
    for y in range(cap.h // 4, cap.h * 3 // 4, 16):
        y &= ~3
        for x in range(cap.w // 4, cap.w * 3 // 4, 16):
            x &= ~3
            for dy in range(4):
                base = (y + dy) * stride
                for dx in range(4):
                    o = base + (x + dx) * 2
                    sums[dy * 4 + dx] += mv[o] | (mv[o + 1] << 8)
            cnt += 1
    fcntl.ioctl(cap.fd, msd.VIDIOC_QBUF, b)
    return [s / cnt for s in sums]


if __name__ == "__main__":
    main()
