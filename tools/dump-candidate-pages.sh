#!/bin/bash
# Dump the candidate register pages in full and test which are address aliases.
#
# WHY ALIASING MATTERS. The page map flagged several pages as "populated but
# never written by the driver", which sounds like undiscovered silicon. But
# 0x41xx has the same non-zero count as 0x40xx with identical values, and
# 0x5801..0x5804 match 0x5781..0x5784. If those are aliases - the address
# decoder ignoring a bit - then they are the SAME registers seen twice, not new
# ones, and toggling them would just be poking a block we already understand.
#
# So dump the candidates and the pages they resemble, and compare them byte for
# byte before drawing any conclusion about what is undiscovered.
#
# Read-only. Sensor registers are volatile in any case.
#
# Run as root:  sudo ./dump-candidate-pages.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENSOR=0x36
OUT="$HERE/../data/sensor-pages"
# Candidates from the map, plus the pages they might alias.
PAGES="32 33 3d 3e 3f 40 41 43 50 57 58 5a"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$OUT"

SYS="$(readlink -f /sys/bus/i2c/devices/i2c-OVTI5678:00 2>/dev/null || true)"
[ -n "$SYS" ] || { echo "ERROR: sensor i2c client missing" >&2; exit 1; }
BUS="$(basename "$(dirname "$SYS")")"; BUS="${BUS#i2c-}"

gst-launch-1.0 -q v4l2src device=/dev/video0 ! fakesink sync=false >/dev/null 2>&1 &
CAPPID=$!
trap 'kill "$CAPPID" 2>/dev/null; wait "$CAPPID" 2>/dev/null' EXIT
sleep 3

echo "== validating =="
id="$(i2ctransfer -f -y "$BUS" "w2@$SENSOR" 0x30 0x0a r3 2>/dev/null)"
case "$id" in
    *0x00*0x56*0x75*) pass "chip id $id" ;;
    *) fail "chip id wrong ($id) - aborting"; exit 1 ;;
esac
echo

echo "== dumping pages =="
for p in $PAGES; do
    i2ctransfer -f -y "$BUS" "w2@$SENSOR" "0x$p" 0x00 r256 2>/dev/null \
        | tr ' ' '\n' | grep -c . >/dev/null
    i2ctransfer -f -y "$BUS" "w2@$SENSOR" "0x$p" 0x00 r256 2>/dev/null > "$OUT/page-$p.txt"
    n=$(tr ' ' '\n' < "$OUT/page-$p.txt" | grep -vc '^0x00$' || true)
    printf '  0x%s00  %3d non-zero\n' "$p" "$n"
done
chown -R --reference="$HERE" "$OUT" 2>/dev/null || true
echo

echo "== alias check: pages that are byte-for-byte identical =="
found=0
for a in $PAGES; do
    for b in $PAGES; do
        [ "$a" \< "$b" ] || continue
        if cmp -s "$OUT/page-$a.txt" "$OUT/page-$b.txt"; then
            printf '  0x%s00 == 0x%s00   \033[33mALIAS\033[0m (same registers seen twice)\n' "$a" "$b"
            found=1
        fi
    done
done
[ "$found" -eq 0 ] && echo "  none identical - each page is distinct"
echo

echo "== 0x3300 in full (the densest untouched page) =="
awk '{
  n = split($0, b, " ")
  for (i = 1; i <= n; i++) {
    if ((i-1) % 16 == 0) printf "\n  33%02x: ", i-1
    printf "%s ", substr(b[i], 3)
  }
} END {print ""}' "$OUT/page-33.txt"
echo
echo "pages saved under $OUT/"
