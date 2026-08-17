#!/bin/bash
# Read the front camera module's EEPROM at i2c 0x51.
#
# ACPI declares it: L0EE=0x9 with a second i2c address L0A1=0x51, on the same
# bus as the sensor (i2c-1 here, the DesignWare adapter at PCI 00:15.1).
# Windows never gave it up - ov5678.sys references C:\NVMDump\{WF,UF}_NVM.bin
# but the files are not present on any install we have seen.
#
# WHY A COLD READ FAILS. The EEPROM sits on the camera module and is powered by
# the same rails as the sensor. Charles Drolet found that i2c-1 gives controller
# timeouts whenever the rails are down, and that VSIO, AUX1 and AUX2 must all be
# enabled together before the bus responds at all. So this script powers the
# sensor first, by holding a capture open, and verifies the rails really came up
# before touching the bus.
#
# THE ONE REAL HAZARD - READ THIS BEFORE CHANGING THE PROBE ORDER.
#
# Reading an EEPROM means writing an address pointer, then reading. The width of
# that pointer is what makes this dangerous:
#
#   8-bit device,  we send 1 address byte   -> read.  Safe.
#   16-bit device, we send 2 address bytes  -> read.  Safe.
#   16-bit device, we send 1 address byte   -> incomplete address, no write.
#                                              Harmless; the read is garbage.
#   8-bit device,  we send 2 address bytes  -> the second byte is DATA.
#                                              THIS IS A WRITE.
#
# That last case would overwrite a byte of factory calibration data, on a part
# whose contents cannot be regenerated. So the 8-bit probe is safe under either
# hypothesis and runs by default; the 16-bit probe is opt-in behind
# --allow-16bit and is refused otherwise.
#
# Run as root:  sudo ./read-eeprom.sh                 safe probes only
#               sudo ./read-eeprom.sh --allow-16bit   also try 16-bit addressing

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/../data"
ADDR=0x51
ALLOW16=0
[ "${1:-}" = "--allow-16bit" ] && ALLOW16=1

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$OUT"

# --- which bus is the sensor on -------------------------------------------
# Derive it rather than hardcoding: the DesignWare adapters are not guaranteed
# to enumerate in the same order.
SYS="$(readlink -f /sys/bus/i2c/devices/i2c-OVTI5678:00 2>/dev/null || true)"
[ -n "$SYS" ] || { echo "ERROR: i2c-OVTI5678:00 does not exist - is the camera up?" >&2; exit 1; }

# The bus is the parent directory: .../i2c-1/i2c-OVTI5678:00 -> i2c-1 -> 1.
# Do NOT scrape digits out of the full path with a bare [0-9]+ regex: the
# string "i2c" contains a 2, so the first digit found is that, not the bus
# number. An earlier version did exactly that and resolved to bus 2 - the REAR
# camera's bus - which in 16-bit mode would have written to the wrong module.
BUS="$(basename "$(dirname "$SYS")")"
BUS="${BUS#i2c-}"
case "$BUS" in
    ''|*[!0-9]*) echo "ERROR: derived a non-numeric i2c bus ('$BUS') from $SYS" >&2; exit 1 ;;
esac

# Cross-check against the sensor's own client name, which the kernel prints as
# <bus>-<addr>. If these disagree, stop rather than guess.
CLIENT="$(ls /sys/bus/i2c/drivers/ov5675/ 2>/dev/null | grep -E '^[0-9]+-[0-9a-f]+$' | head -1)"
if [ -n "$CLIENT" ] && [ "${CLIENT%%-*}" != "$BUS" ]; then
    echo "ERROR: bus mismatch - sysfs path says $BUS, ov5675 client says ${CLIENT%%-*}" >&2
    exit 1
fi
echo "== front sensor is on i2c-$BUS, EEPROM expected at $ADDR =="
echo

# --- power the module ------------------------------------------------------
rails_up() {
    local n=0 s
    for d in /sys/class/regulator/regulator.*; do
        case "$(cat "$d/name" 2>/dev/null)" in
            VSIO|AUX1|AUX2)
                s="$(cat "$d/state" 2>/dev/null)"
                [ "$s" = "enabled" ] && n=$((n + 1)) ;;
        esac
    done
    [ "$n" -eq 3 ]
}

echo "== powering the module (holding a capture open) =="
gst-launch-1.0 -q v4l2src device=/dev/video0 ! fakesink sync=false >/dev/null 2>&1 &
CAPPID=$!
trap 'kill "$CAPPID" 2>/dev/null; wait "$CAPPID" 2>/dev/null' EXIT

for i in $(seq 1 20); do
    rails_up && break
    sleep 0.5
done

if rails_up; then
    pass "VSIO, AUX1 and AUX2 all enabled"
else
    fail "rails did not come up - the bus will time out, aborting"
    info "is v4l2-relayd running and /dev/video0 fed? try tools/check-camera.sh"
    exit 1
fi
echo

# --- does anything answer at 0x51 ------------------------------------------
# Pure read, no address written at all: cannot modify anything under any
# hypothesis about the device.
echo "== probing $ADDR (read-only, no address written) =="
if RAW="$(i2ctransfer -f -y "$BUS" "r8@$ADDR" 2>&1)"; then
    pass "device ACKs at $ADDR"
    info "first 8 bytes from the current pointer: $RAW"
else
    fail "no response at $ADDR: $RAW"
    info "if this says 'Remote I/O error' the rails may have dropped again"
    exit 1
fi
echo

# --- 8-bit addressing (safe under both hypotheses) -------------------------
echo "== 8-bit addressed reads =="
for off in 0x00 0x10 0x20; do
    if r="$(i2ctransfer -f -y "$BUS" "w1@$ADDR" "$off" "r16@$ADDR" 2>&1)"; then
        printf '  offset %-5s %s\n' "$off" "$r"
    else
        printf '  offset %-5s FAILED: %s\n' "$off" "$r"
    fi
done
echo
info "If those three rows are identical, the pointer is not being honoured and"
info "the part is probably 16-bit addressed - see --allow-16bit."
echo

# --- 16-bit addressing (opt-in: can WRITE to an 8-bit part) ----------------
if [ "$ALLOW16" -eq 0 ]; then
    echo "== 16-bit addressing not attempted =="
    info "Sending two address bytes to an 8-bit EEPROM writes the second one."
    info "Re-run with --allow-16bit only once you accept that risk."
    exit 0
fi

echo "== 16-bit addressed read (opt-in) =="

# THE FIRST 2-BYTE WRITE IS THE RISKY MOMENT, so make it idempotent.
#
# Under the 8-bit hypothesis, sending [A][B] writes B to offset A. The 8-bit
# probe above read offset 0x00 as 0xff, so sending [0x00][0xff] would write
# 0xff over a byte that already holds 0xff - no change. Under the 16-bit
# hypothesis the same two bytes simply address 0x00ff and read from there.
#
# So this probe cannot alter the part under EITHER hypothesis, and it still
# discriminates: a 16-bit part returns whatever lives at 0x00ff, while an
# 8-bit part leaves its pointer at 0x01 and returns the 0xff we already saw.
echo "  step 1: idempotent probe at [0x00][0xff] - cannot write under either hypothesis"
probe="$(i2ctransfer -f -y "$BUS" "w2@$ADDR" 0x00 0xff "r16@$ADDR" 2>&1)"
echo "    $probe"

varied="$(echo "$probe" | tr ' ' '\n' | sort -u | grep -c '^0x')"
if [ "$varied" -le 1 ]; then
    fail "probe returned a single repeated value - 16-bit NOT confirmed"
    info "Stopping. Reading further would mean writing 2 address bytes to a part"
    info "that may be 8-bit, which would overwrite factory calibration."
    exit 1
fi
pass "16-bit addressing confirmed ($varied distinct byte values) - full read is safe"
echo
DUMP="$OUT/eeprom-0x51.bin"
: > "$DUMP"
ok=1
for ((page = 0; page < 8192; page += 32)); do
    hi=$(printf '0x%02x' $(((page >> 8) & 0xff)))
    lo=$(printf '0x%02x' $((page & 0xff)))
    if r="$(i2ctransfer -f -y "$BUS" "w2@$ADDR" "$hi" "$lo" "r32@$ADDR" 2>/dev/null)"; then
        for b in $r; do printf '%b' "\\x${b#0x}"; done >> "$DUMP"
    else
        ok=0; break
    fi
done

if [ "$ok" -eq 1 ] && [ -s "$DUMP" ]; then
    pass "dumped $(stat -c%s "$DUMP") bytes to $DUMP"
    # The real size is unknown; a part smaller than 8 KiB wraps its address
    # counter, so the dump repeats. Detect that rather than reporting phantom
    # capacity.
    python3 - "$DUMP" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
for size in (256, 512, 1024, 2048, 4096):
    if len(d) > size and d[:size] == d[size:2 * size]:
        print(f"  NOTE: content repeats every {size} bytes - the part is "
              f"probably {size} bytes and the address counter wrapped")
        break
PY
    chown --reference="$HERE" "$DUMP" 2>/dev/null || true
    echo
    echo "== first 256 bytes =="
    hexdump -C "$DUMP" | head -16 | sed 's/^/  /'
    echo
    echo "== is it all 0xff or all 0x00 (i.e. nothing really read)? =="
    python3 - "$DUMP" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read()
c = collections.Counter(d)
top, n = c.most_common(1)[0]
print(f"  {len(d)} bytes, {len(c)} distinct values, most common 0x{top:02x} x{n} ({100*n/len(d):.1f}%)")
if len(c) <= 2:
    print("  WARNING: almost no variation - this is probably not real content")
PY
else
    fail "16-bit read failed or returned nothing"
fi
