#!/bin/bash
# Map which register pages on the sensor actually contain anything, and flag
# the ones ov5675.c never writes.
#
# WHY THIS RATHER THAN MORE PAGE DUMPS. 0x51xx and 0x56xx came back 256 zeros
# each, so guessing pages is expensive and mostly finds nothing. What matters
# for the Bayer-mode question is narrower: a page that is POPULATED but that
# the driver never touches. Registers the driver writes are understood; empty
# pages are not implemented; the interesting set is the intersection.
#
# SPEED. Tries a sequential (auto-increment) read first - one i2c transaction
# per page instead of 256 - and verifies it against the known chip id bytes
# before relying on it. Falls back to per-register reads if the sensor does not
# auto-increment.
#
# Read-only. Sensor registers are volatile anyway.
#
# Run as root:  sudo ./map-sensor-regs.sh [first_page] [last_page]
#               defaults to 0x30..0x5f (i.e. 0x3000..0x5fff)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENSOR=0x36
P0="${1:-0x30}"
P1="${2:-0x5f}"
OUT="$HERE/../data/sensor-reg-map.txt"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

SYS="$(readlink -f /sys/bus/i2c/devices/i2c-OVTI5678:00 2>/dev/null || true)"
[ -n "$SYS" ] || { echo "ERROR: sensor i2c client missing" >&2; exit 1; }
BUS="$(basename "$(dirname "$SYS")")"; BUS="${BUS#i2c-}"
case "$BUS" in ''|*[!0-9]*) echo "ERROR: bad bus '$BUS'" >&2; exit 1 ;; esac

gst-launch-1.0 -q v4l2src device=/dev/video0 ! fakesink sync=false >/dev/null 2>&1 &
CAPPID=$!
trap 'kill "$CAPPID" 2>/dev/null; wait "$CAPPID" 2>/dev/null' EXIT
sleep 3

echo "== validating i2c and testing sequential read =="
# Single-byte reads of the chip id, known to be 00 56 75.
one=""
for r in 0x300a 0x300b 0x300c; do
    one="$one $(i2ctransfer -f -y "$BUS" "w2@$SENSOR" 0x30 "$(printf '0x%02x' $((r & 0xff)))" r1 2>/dev/null)"
done
echo "   single reads at 0x300a..c:$one"
case "$one" in
    *0x00*0x56*0x75*) pass "i2c reads verified" ;;
    *) fail "chip id wrong - aborting"; exit 1 ;;
esac

# Now the same three bytes in ONE transaction. If auto-increment works this
# matches; if not, it will not, and we fall back rather than dumping garbage.
seq3="$(i2ctransfer -f -y "$BUS" "w2@$SENSOR" 0x30 0x0a r3 2>/dev/null)"
echo "   sequential read of the same three:$seq3"
BULK=0
case "$seq3" in
    *0x00*0x56*0x75*) BULK=1; pass "auto-increment works - using one read per page" ;;
    *) fail "no auto-increment - falling back to per-register reads (slower)" ;;
esac
echo

# --- pages ov5675.c writes --------------------------------------------------
DRIVER_PAGES="$(grep -oE '\{0x[0-9a-fA-F]{4},' "$HERE/../sensor-ov5675/ov5675.c" \
                | sed 's/{0x//; s/,//' | cut -c1-2 | tr 'A-F' 'a-f' | sort -u | tr '\n' ' ')"
echo "== pages ov5675.c writes: $DRIVER_PAGES=="
echo

read_page() {                          # $1 = page byte -> space separated bytes
    local p="$1"
    if [ "$BULK" -eq 1 ]; then
        i2ctransfer -f -y "$BUS" "w2@$SENSOR" "$p" 0x00 r256 2>/dev/null
    else
        local out="" i
        for ((i = 0; i < 256; i += 1)); do
            out="$out $(i2ctransfer -f -y "$BUS" "w2@$SENSOR" "$p" \
                        "$(printf '0x%02x' $i)" r1 2>/dev/null)"
        done
        echo "$out"
    fi
}

echo "== scanning pages 0x${P0#0x}00 .. 0x${P1#0x}ff =="
{
    echo "# sensor register page map  $(date -Is)"
    printf '%-8s %-8s %-9s %s\n' "page" "nonzero" "driver?" "first few non-zero"
} > "$OUT"

for ((p = P0; p <= P1; p++)); do
    ph="$(printf '%02x' "$p")"
    bytes="$(read_page "0x$ph")"
    [ -n "$bytes" ] || continue
    nz=0; sample=""
    i=0
    for b in $bytes; do
        if [ "$b" != "0x00" ]; then
            nz=$((nz + 1))
            [ ${#sample} -lt 40 ] && sample="$sample $(printf '%02x' $i)=$b"
        fi
        i=$((i + 1))
    done
    case " $DRIVER_PAGES " in
        *" $ph "*) drv="written" ;;
        *)         drv="UNTOUCHED" ;;
    esac
    if [ "$nz" -gt 0 ]; then
        printf '0x%s00   %-8s %-9s %s\n' "$ph" "$nz" "$drv" "$sample" | tee -a "$OUT"
    fi
done

echo
echo "== populated pages the driver NEVER writes - the candidates =="
awk '$3 == "UNTOUCHED"' "$OUT" | sed 's/^/  /'
chown --reference="$HERE" "$OUT" 2>/dev/null || true
echo
echo "full map: $OUT"
