#!/usr/bin/env python3
"""Bit-sweep the sensor's ISP control registers looking for a Bayer output mode.

WHAT THIS IS FOR
    Sakari Ailus asked whether this sensor can be programmed to emit Bayer
    instead of RGB-IR. Mapping the register space found no obvious CFA or
    output-format control, but 0x5000..0x5003 - the ISP control block - were
    never swept, and ov5675.c writes only 0x5000 of the four. This sweeps every
    bit of those registers and measures the mosaic after each change.

THE TEST
    A frame is captured at full resolution and the mean of each of the 16
    positions in the 4x4 cell is taken. Today the four infrared positions agree
    with each other to well under 1% and sit near 12% of green. If a bit makes
    the sensor emit Bayer, those four stop being a tight, dark cluster - either
    they rise toward the colour positions, or their agreement breaks.

    Reported per candidate:
      ir/green   IR mean over green mean       (~0.12 now; toward 1.0 = colour)
      ir spread  max-min across the 4 IR spots (~1% now; large = not one channel)
      green      absolute level, to catch a bit that just changes exposure

WHY THIS IS SAFE
    Sensor registers are volatile. Every write is restored immediately, and a
    module reload power-cycles the part back to defaults regardless. Nothing
    here can persist, which is what makes a blind sweep reasonable at all -
    unlike the EEPROM.

Run as root, with v4l2-relayd stopped:
    sudo systemctl stop ov5678-ondemand.service
    sudo tools/sweep-isp-bits.py
"""

import importlib.util
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "msd", os.path.join(HERE, "measure-sensor-delays.py"))
msd = importlib.util.module_from_spec(spec)
sys.modules["msd"] = msd
spec.loader.exec_module(msd)

spec2 = importlib.util.spec_from_file_location(
    "crgbir", os.path.join(HERE, "check-rgbir.py"))
crgbir = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(crgbir)

SENSOR = "0x36"
# Intel's declared mosaic: rows GIGI / RGBG / GIGI / BGRG.
IR_POS = [(0, 1), (0, 3), (2, 1), (2, 3)]
G_POS = [(0, 0), (0, 2), (1, 1), (1, 3), (2, 0), (2, 2), (3, 1), (3, 3)]
# 0x5000 is the only one of these ov5675.c writes (to 0x77).
CANDIDATES = [0x5000, 0x5001, 0x5002, 0x5003]


def bus():
    p = os.path.realpath("/sys/bus/i2c/devices/i2c-OVTI5678:00")
    b = os.path.basename(os.path.dirname(p))
    assert b.startswith("i2c-"), f"unexpected sysfs path {p}"
    return b[4:]


def rd(b, reg):
    out = subprocess.run(
        ["i2ctransfer", "-f", "-y", b, f"w2@{SENSOR}",
         f"0x{(reg >> 8) & 0xff:02x}", f"0x{reg & 0xff:02x}", "r1"],
        capture_output=True, text=True)
    t = out.stdout.strip()
    return int(t, 16) if t.startswith("0x") else None


def wr(b, reg, val):
    subprocess.run(
        ["i2ctransfer", "-f", "-y", b, f"w3@{SENSOR}",
         f"0x{(reg >> 8) & 0xff:02x}", f"0x{reg & 0xff:02x}", f"0x{val:02x}"],
        capture_output=True, text=True)
    # Always verify: a write that silently did not land would look exactly like
    # a bit with no effect, and we would record a false negative.
    return rd(b, reg)


def signature(cap, black=64):
    # NOTE: `black` is assumed, not measured, and that produced a false hit.
    # 0x5000 bit0 turns out to be the black-level correction enable: clearing
    # it lifts EVERY position by the pedestal (~64 counts), which barely moves
    # green (~285) but quadruples the IR positions (~83), so a uniform shift
    # showed up as "the IR cluster changed". Judge any flagged candidate from
    # the full 16-position grid, where a pedestal shift is obvious because all
    # sixteen move together, rather than from the ratio alone.
    m = crgbir.means16(cap)
    def at(p): return max(m[p[0] * 4 + p[1]] - black, 0.0)
    ir = [at(p) for p in IR_POS]
    g = sum(at(p) for p in G_POS) / len(G_POS)
    irm = sum(ir) / len(ir)
    spread = (max(ir) - min(ir)) / irm * 100 if irm > 0 else 0.0
    return irm / g if g > 0 else 0.0, spread, g


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root")

    b = bus()
    print(f"sensor 0x36 on i2c-{b}\n")

    graph = msd.parse_graph()
    found = msd.locate(graph)
    if not found:
        sys.exit("could not locate the sensor path")
    sname, csi, cpad, cap_ent, node, fmt = found
    subdev = graph[sname]["node"]

    # Full resolution only. The 1296x972 mode is 2x2 binned, which averages the
    # IR pixels in with colour ones and destroys the very structure this sweep
    # measures - a binned capture would report "no change" for every bit.
    fmt = (fmt[0], 2592, 1944)
    msd.setup_pipeline(sname, csi, cpad, cap_ent, fmt)

    # The capture node's pixel format must match the subdev mbus code or IPU6
    # link validation fails STREAMON with EPIPE.
    PIXFMT = {"SGRBG10_1X10": "BA10", "SGBRG10_1X10": "GB10",
              "SBGGR10_1X10": "BG10", "SRGGB10_1X10": "RG10"}
    pf = PIXFMT.get(fmt[0])
    if not pf:
        sys.exit(f"unhandled mbus code {fmt[0]}")
    cap = msd.Capture(node, want=(fmt[1], fmt[2]), pixfmt=pf)
    if cap.fourcc != pf:
        sys.exit(f"node negotiated {cap.fourcc}, not {pf}")
    print(f"sensor {sname} {subdev}   capture {node}   {fmt[0]} -> {pf}")
    ctrls = msd.Ctrls(subdev)

    emin, emax = msd.ctrl_range(subdev, "exposure")
    gmin, gmax = msd.ctrl_range(subdev, "analogue_gain")
    ctrls.set(msd.CID_EXPOSURE, min(2016, emax))
    ctrls.set(msd.CID_ANALOGUE_GAIN, min(512, gmax))
    cap.start()
    for _ in range(12):
        cap.frame()

    base_ratio, base_spread, base_g = signature(cap)
    print(f"baseline   ir/green {base_ratio:.4f}   ir spread {base_spread:5.2f}%"
          f"   green {base_g:7.1f}")
    if base_ratio > 0.5:
        print("  the IR positions are not a dark cluster - is the mosaic what we think?")
    print()

    originals = {r: rd(b, r) for r in CANDIDATES}
    print("current values: " + "  ".join(
        f"0x{r:04x}=0x{v:02x}" for r, v in originals.items()) + "\n")

    hits = []
    try:
        for reg in CANDIDATES:
            orig = originals[reg]
            if orig is None:
                print(f"0x{reg:04x}: unreadable, skipping")
                continue
            for bit in range(8):
                val = orig ^ (1 << bit)
                got = wr(b, reg, val)
                if got != val:
                    print(f"0x{reg:04x} bit{bit}: write rejected "
                          f"(wrote 0x{val:02x}, reads 0x{got if got is not None else -1:02x}) - skipped")
                    wr(b, reg, orig)
                    continue
                for _ in range(6):
                    cap.frame()
                ratio, spread, g = signature(cap)
                d_ratio = ratio - base_ratio
                d_g = (g - base_g) / base_g * 100 if base_g else 0
                flag = ""
                if ratio > base_ratio * 2 or spread > 10:
                    flag = "  <<< IR CLUSTER CHANGED"
                    hits.append((reg, bit, ratio, spread, g))
                elif abs(d_g) > 5:
                    flag = "  (level moved, mosaic unchanged)"
                print(f"0x{reg:04x} bit{bit} -> 0x{val:02x}   ir/green {ratio:.4f} "
                      f"({d_ratio:+.4f})   spread {spread:5.2f}%   green {g:7.1f} "
                      f"({d_g:+5.1f}%){flag}")
                wr(b, reg, orig)
                for _ in range(4):
                    cap.frame()
    finally:
        # Restore and VERIFY while still streaming. Reading back after
        # cap.close() returns None: closing drops the rails and the i2c bus
        # stops answering, which is what Charles found and what an earlier
        # version of this crashed on.
        restored = []
        for r, v in originals.items():
            if v is not None:
                got = wr(b, r, v)
                restored.append(f"0x{r:04x}=0x{got:02x}" if got is not None
                                else f"0x{r:04x}=UNVERIFIED")
        print("\nrestored (verified while powered): " + "  ".join(restored))
        print("(registers are volatile in any case - closing the device "
              "power-cycles the sensor back to defaults)")
        cap.stop()
        cap.close()

    print()
    if hits:
        print("CANDIDATES THAT MOVED THE IR CLUSTER:")
        for reg, bit, ratio, spread, g in hits:
            print(f"  0x{reg:04x} bit{bit}  ir/green {ratio:.4f}  spread {spread:.2f}%")
        print("\nVerify any of these properly with tools/check-rgbir.sh before")
        print("believing it - this sweep uses one frame per candidate.")
    else:
        print("No bit moved the IR cluster. On this evidence 0x5000..0x5003")
        print("contains no RGB-IR/Bayer mode control.")


if __name__ == "__main__":
    main()
