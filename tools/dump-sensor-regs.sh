#!/bin/bash
# Dump the front sensor's registers over i2c, to hunt for a Bayer output mode.
#
# WHY. Sakari Ailus asked whether this sensor can be programmed to emit Bayer
# instead of RGB-IR. If it can, the whole RGB-IR problem collapses: patch 2/3
# becomes acceptable upstream, no media bus code is needed, and no pre-pass or
# shader work is required. Intel's evidence points the other way - the IPU6 has
# an x2b_rgbir block of 314 registers, i.e. they convert in the IPU6, not the
# sensor - but that shows what Intel does, not what the sensor can do.
#
# WHERE TO LOOK. ov5675.c writes 138 registers, but only ONE of them
# (0x5000 = 0x77) is in the 0x50xx page, which on OmniVision parts is the ISP
# control block. So 255 registers there sit at their power-on defaults, and a
# colour-processing mode would plausibly be gated in exactly that page.
#
# SAFETY. This reads only. Even writes would be recoverable - sensor registers
# are volatile and a module reload power-cycles the part - which is what makes
# this hunt cheap compared with the EEPROM.
#
# The sensor must be powered, so a capture is held open, exactly as for the
# EEPROM read.
#
# Run as root:  sudo ./dump-sensor-regs.sh [start] [end]
#               defaults to the ISP page, 0x5000..0x50ff

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENSOR=0x36
START="${1:-0x5000}"
END="${2:-0x50ff}"
OUT="$HERE/../data/sensor-regs-$(printf '%04x' $((START)))-$(printf '%04x' $((END))).txt"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

SYS="$(readlink -f /sys/bus/i2c/devices/i2c-OVTI5678:00 2>/dev/null || true)"
[ -n "$SYS" ] || { echo "ERROR: sensor i2c client missing" >&2; exit 1; }
BUS="$(basename "$(dirname "$SYS")")"; BUS="${BUS#i2c-}"
case "$BUS" in ''|*[!0-9]*) echo "ERROR: bad bus '$BUS'" >&2; exit 1 ;; esac
echo "== sensor at $SENSOR on i2c-$BUS =="

# --- power ------------------------------------------------------------------
gst-launch-1.0 -q v4l2src device=/dev/video0 ! fakesink sync=false >/dev/null 2>&1 &
CAPPID=$!
trap 'kill "$CAPPID" 2>/dev/null; wait "$CAPPID" 2>/dev/null' EXIT
sleep 3

rd() {                                # $1 = 16-bit register -> hex byte, or ""
    local hi lo
    hi=$(printf '0x%02x' $((($1 >> 8) & 0xff)))
    lo=$(printf '0x%02x' $(($1 & 0xff)))
    i2ctransfer -f -y "$BUS" "w2@$SENSOR" "$hi" "$lo" "r1" 2>/dev/null
}

# --- validate the method before trusting any of it --------------------------
# Chip id lives at 0x300a..0x300c and must read 00 56 75. If this does not
# match, the reads are meaningless and everything below is noise.
echo "== validating: chip id at 0x300a..0x300c should be 0x00 0x56 0x75 =="
id=""
for r in 0x300a 0x300b 0x300c; do id="$id $(rd $((r)))"; done
echo "   read:$id"
case "$id" in
    *0x00*0x56*0x75*) pass "chip id correct - i2c reads are trustworthy" ;;
    *) fail "chip id mismatch - aborting, the dump would be garbage"
       echo "   (is the sensor powered? are the rails up?)" >&2
       exit 1 ;;
esac
echo

# --- the dump ---------------------------------------------------------------
echo "== dumping 0x$(printf '%04x' $((START)))..0x$(printf '%04x' $((END))) =="
{
    echo "# ov5678/ov5675 register dump"
    echo "# $(date -Is)  bus i2c-$BUS  addr $SENSOR"
    for ((r = START; r <= END; r++)); do
        v="$(rd "$r")"
        [ -n "$v" ] && printf '0x%04x %s\n' "$r" "$v"
    done
} > "$OUT"

n=$(grep -c '^0x' "$OUT")
pass "read $n registers -> $OUT"
chown --reference="$HERE" "$OUT" 2>/dev/null || true
echo

# --- show the non-zero ones, which is where anything interesting is ---------
echo "== non-zero registers (defaults that are actually set) =="
awk '$2 != "0x00" {printf "  %s %s\n", $1, $2}' "$OUT" | head -40
echo
echo "total non-zero: $(awk '$2 != "0x00"' "$OUT" | grep -c '^0x')"
