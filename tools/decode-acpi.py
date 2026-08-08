#!/usr/bin/env python3
"""Decode the buffers collected by collect-acpi.sh into the fields the
TPS68470 board data needs (Phase A).

Reads ../data/*.raw (acpi_call replies) and prints CLDB, SSDB and _CRS
decodes plus annotated hexdumps. Nothing here touches the system.
"""

import os
import re
import struct
import sys

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
if len(sys.argv) > 1:
    DATA = sys.argv[1]


def load(name):
    """Parse an acpi_call reply into bytes, or return (None, reason)."""
    path = os.path.join(DATA, name + ".raw")
    if not os.path.exists(path):
        return None, "missing %s" % os.path.basename(path)
    text = open(path, "r", errors="replace").read().strip().strip("\x00")
    if not text:
        return None, "empty reply"
    if "Error" in text or "not found" in text.lower():
        return None, text.strip()
    if "{" not in text:
        # Integer or string reply - pass it through for the caller to show.
        return None, "not a buffer: %s" % text.strip()
    body = text[text.index("{") + 1: text.rindex("}") if "}" in text else len(text)]
    vals = re.findall(r"0x([0-9a-fA-F]{1,2})", body)
    return bytes(int(v, 16) for v in vals), None


def hexdump(b, highlight=None):
    """Annotated hexdump; highlight is {offset: label}."""
    highlight = highlight or {}
    out = []
    for off in range(0, len(b), 16):
        chunk = b[off:off + 16]
        hexpart = " ".join("%02x" % c for c in chunk)
        labels = [highlight[o] for o in range(off, off + len(chunk)) if o in highlight]
        line = "  %04x  %-47s" % (off, hexpart)
        if labels:
            line += "  <- " + ", ".join(labels)
        out.append(line)
    return "\n".join(out)


# --------------------------------------------------------------------------- CLDB
# struct int3472_cldb, from include/linux/platform_data/x86/int3472.h (32 bytes)
CONTROL_LOGIC_TYPE = {0: "UNKNOWN", 1: "DISCRETE (CRD-D)", 2: "PMIC TPS68470", 3: "PMIC uP6641"}


def decode_cldb(b):
    print("CLDB  (control logic / PMIC description)  %d bytes" % len(b))
    if len(b) < 32:
        print("  ! short buffer, expected >= 32")
    if len(b) >= 4:
        version, clt, clid, sku = b[0], b[1], b[2], b[3]
        print("  version            0x%02x" % version)
        print("  control_logic_type 0x%02x  (%s)" % (clt, CONTROL_LOGIC_TYPE.get(clt, "?")))
        print("  control_logic_id   0x%02x   <- must match SSDB controllogicid" % clid)
        print("  sensor_card_sku    0x%02x" % sku)
    if len(b) >= 15:
        print("  clock_source       0x%02x" % b[14])
    # Exact NVS->offset mapping, read out of this machine's DSDT
    # (\_SB.PC00.CLP0.CLDB): C0W0..C0W5 land at 0x08..0x0d, inside the
    # kernel struct's reserved[10]. Offset 0x02 is never written, so
    # control_logic_id is statically 0.
    if len(b) >= 0x0E:
        print("  C0IC   @0x04       0x%02x" % b[4])
        print("  C0SP   @0x06       0x%02x" % b[6])
        print("  GPIO pin assignments (C0W0..C0W5 @0x08..0x0d):")
        for i in range(6):
            print("        C0W%d = 0x%02x (%d)%s"
                  % (i, b[8 + i], b[8 + i], "" if b[8 + i] else "   (unused)"))
    marks = {0: "version (C0VE)", 1: "control_logic_type (C0TP)",
             2: "control_logic_id (static 0)", 3: "sensor_card_sku (C0CV)",
             4: "C0IC", 6: "C0SP", 8: "C0W0..C0W5", 14: "clock_source"}
    print(hexdump(b, marks))


# --------------------------------------------------------------------------- SSDB
SSDB_FIELDS = [
    ("version",            0x00, "B"),
    ("sku",                0x01, "B"),
    ("devfunction",        0x12, "B"),
    ("bus",                0x13, "B"),
    ("dphylinkenfuses",    0x14, "I"),
    ("clockdiv",           0x18, "I"),
    ("link",               0x1C, "B"),   # CSI-2 port
    ("lanes",              0x1D, "B"),   # lane count
    ("maxlanespeed",       0x46, "I"),
    ("sensorcalibfileidx", 0x4A, "B"),
    ("romtype",            0x4E, "B"),   # EEPROM
    ("vcmtype",            0x4F, "B"),   # focus motor
    ("platforminfo",       0x50, "B"),
    ("platformsubinfo",    0x51, "B"),
    ("flash",              0x52, "B"),
    ("privacyled",         0x53, "B"),
    ("degree",             0x54, "B"),   # rotation
    ("mipilinkdefined",    0x55, "B"),
    ("mclkspeed",          0x56, "I"),   # external clock, Hz
    ("controllogicid",     0x5A, "B"),   # which INT3472
    ("mclkport",           0x5E, "B"),
]


def decode_ssdb(b, label):
    print("SSDB  (%s)  %d bytes" % (label, len(b)))
    if len(b) < 0x6C:
        print("  ! short buffer, expected 0x6c (108)")
    vals = {}
    for name, off, fmt in SSDB_FIELDS:
        size = struct.calcsize("<" + fmt)
        if off + size > len(b):
            continue
        (v,) = struct.unpack_from("<" + fmt, b, off)
        vals[name] = v
        extra = ""
        if name == "mclkspeed":
            extra = "  = %.3f MHz" % (v / 1e6)
        elif name == "maxlanespeed":
            extra = "  = %.3f MHz" % (v / 1e6) if v else "  (unset)"
        elif name in ("romtype", "vcmtype", "privacyled", "flash"):
            extra = "  (%s)" % ("present" if v not in (0, 0xFF) else "none/unset")
        elif name == "degree":
            extra = "  (rotation)"
        print("  %-18s 0x%08x  %-10d%s" % (name, v, v, extra))

    if "mclkspeed" in vals:
        mhz = vals["mclkspeed"] / 1e6
        if abs(mhz - 19.2) < 0.2 or abs(mhz - 24.0) < 0.2:
            print("  -> MCLK %.1f MHz is supported by clk-tps68470 clk_freqs[]" % mhz)
        else:
            print("  -> MCLK %.3f MHz is NOT one of the clk-tps68470 values (19.2 / 24)" % mhz)

    marks = {off: name for name, off, _ in SSDB_FIELDS}
    print(hexdump(b, marks))
    return vals


# --------------------------------------------------------------------------- _CRS
SERIAL_BUS_TYPE = {1: "I2C", 2: "SPI", 3: "UART"}


def decode_crs(b, label):
    """Walk ACPI resource descriptors; decode I2cSerialBus and GPIO entries."""
    print("_CRS  (%s)  %d bytes" % (label, len(b)))
    i = 0
    while i < len(b):
        tag = b[i]
        if tag == 0x79 or tag == 0x78:          # End tag
            break
        if tag & 0x80:                          # Large descriptor
            if i + 3 > len(b):
                break
            dlen = b[i + 1] | (b[i + 2] << 8)
            item = tag & 0x7F
            body_end = i + 3 + dlen
            d = b[i:body_end]
            if item == 0x0E and len(d) >= 18:   # Serial bus connection
                bus_type = d[5]
                if bus_type == 1:               # I2C
                    speed = struct.unpack_from("<I", d, 12)[0]
                    addr = struct.unpack_from("<H", d, 16)[0]
                    src = d[18:].split(b"\x00")[0].decode("ascii", "replace")
                    print("  I2cSerialBus  address 0x%02x  speed %d Hz  controller '%s'"
                          % (addr, speed, src))
                else:
                    print("  SerialBus type %d (%s)" % (bus_type, SERIAL_BUS_TYPE.get(bus_type, "?")))
            elif item == 0x0C and len(d) >= 23:  # GPIO connection
                conn = d[4]
                pin_off = struct.unpack_from("<H", d, 14)[0]
                src_off = struct.unpack_from("<H", d, 17)[0]
                pins = []
                p = pin_off
                while p + 1 < src_off and p + 1 < len(d):
                    pins.append(struct.unpack_from("<H", d, p)[0])
                    p += 2
                src = d[src_off:].split(b"\x00")[0].decode("ascii", "replace") if src_off < len(d) else "?"
                print("  Gpio%s  pins %s  controller '%s'"
                      % ("Io" if conn == 1 else "Int",
                         ", ".join(str(x) for x in pins) or "-", src))
            else:
                print("  large descriptor 0x%02x, %d bytes" % (item, dlen))
            i = body_end
        else:                                   # Small descriptor
            dlen = tag & 0x07
            print("  small descriptor 0x%02x, %d bytes" % ((tag >> 3) & 0x0F, dlen))
            i += 1 + dlen
    print(hexdump(b))


# --------------------------------------------------------------------------- main
def section(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


def main():
    if not os.path.isdir(DATA):
        print("No data directory. Run collect-acpi.sh first (as root).", file=sys.stderr)
        return 1

    section("CLP0 = INT3472:07  (TPS68470 PMIC, the live control logic)")
    b, err = load("cldb_clp0")
    if b:
        decode_cldb(b)
    else:
        print("  CLDB unavailable: %s" % err)
    print()
    b, err = load("crs_clp0")
    if b:
        decode_crs(b, "CLP0")
    else:
        print("  _CRS unavailable: %s" % err)

    ssdb = {}
    for node, who in (("lnk0", "OVTI5678 / front / 5MP - THE TARGET"),
                      ("lnk1", "OVTI8856 / rear / 8MP")):
        section("%s  (%s)" % (node.upper(), who))
        b, err = load("ssdb_" + node)
        if b:
            ssdb[node] = decode_ssdb(b, who)
        else:
            print("  SSDB unavailable: %s" % err)
        print()
        b, err = load("crs_" + node)
        if b:
            decode_crs(b, node.upper())
        else:
            print("  _CRS unavailable: %s" % err)

    section("Phase A summary")
    for node, who in (("lnk0", "OVTI5678 front"), ("lnk1", "OVTI8856 rear")):
        v = ssdb.get(node)
        if not v:
            print("  %-16s no SSDB" % who)
            continue
        print("  %-16s CSI-2 port %s, %s lanes, MCLK %s Hz, control logic id %s" % (
            who, v.get("link", "?"), v.get("lanes", "?"),
            v.get("mclkspeed", "?"), v.get("controllogicid", "?")))
    print()
    print("  Board data entry needs:  .dev_name = \"i2c-INT3472:07\"")
    print("  DMI:  \"Dell Inc.\" / \"Latitude 7320 Detachable\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
