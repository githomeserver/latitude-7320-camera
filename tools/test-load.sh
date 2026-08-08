#!/bin/bash
# Swap the in-tree int3472 tps68470 module for the locally built one and report.
#
# This touches only the INT3472 PMIC path. It does not load, bind or otherwise
# involve the IPU6, so it cannot hit the intel_ipu6_isys runtime-PM panic.
#
# Run as root:  sudo ./test-load.sh [key=value ...]
#   e.g.        sudo ./test-load.sh rear_reset=9 rear_powerdown=7
#               sudo ./test-load.sh rail_map=1

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Under sudo $HOME is /root, but the module was built as the invoking user.
USER_HOME="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
BUILD="${OV5678_BUILD_DIR:-${USER_HOME:-$HOME}/.cache/ov5678-build}"
KO="$BUILD/intel_skl_int3472_tps68470.ko"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
[ -f "$KO" ] || { echo "ERROR: $KO not built. Run tools/build.sh first." >&2; exit 1; }

MARK="$(date '+%Y-%m-%d %H:%M:%S')"

echo "== before =="
printf '  i2c clients: '; ls /sys/bus/i2c/devices/ | tr '\n' ' '; echo
printf '  int3472 bound: '; [ -e /sys/bus/i2c/devices/i2c-INT3472:07/driver ] && echo yes || echo no

echo
echo "== reloading =="
modprobe -r intel_skl_int3472_tps68470 2>/dev/null
sleep 1
if ! insmod "$KO" "$@"; then
    echo "ERROR: insmod failed" >&2
    exit 1
fi
echo "  inserted with: ${*:-<defaults>}"
sleep 2

echo
echo "== kernel log since load =="
journalctl -k --no-pager --since "$MARK" | \
    grep -iE 'int3472|tps68470|regulator|ov8856|ov5678|gpio' | sed 's/^/  /' || echo "  (nothing)"

echo
echo "== after =="
printf '  int3472 bound: '; [ -e /sys/bus/i2c/devices/i2c-INT3472:07/driver ] && echo yes || echo no

echo "  sensor i2c clients (the Phase A success signal):"
for d in i2c-OVTI5678:00 i2c-OVTI8856:00; do
    if [ -e "/sys/bus/i2c/devices/$d" ]; then
        drv="$(basename "$(readlink -f "/sys/bus/i2c/devices/$d/driver" 2>/dev/null)" 2>/dev/null)"
        printf '    %-18s PRESENT   driver=%s\n' "$d" "${drv:-<none>}"
    else
        printf '    %-18s absent\n' "$d"
    fi
done

echo "  tps68470 cells:"
ls -d /sys/bus/platform/devices/*tps68470* 2>/dev/null | sed 's/^/    /' || echo "    (none)"

echo "  gpiochips:"
for g in /sys/class/gpio/gpiochip*/label /sys/bus/gpio/devices/*/label; do
    [ -f "$g" ] && printf '    %s = %s\n' "$(dirname "$g")" "$(cat "$g")"
done 2>/dev/null | sort -u

echo "  regulators from tps68470:"
grep -l . /sys/class/regulator/*/name 2>/dev/null | while read -r f; do
    n="$(cat "$f")"
    case "$n" in *tps68470*|*TPS68470*) printf '    %-14s %s uV\n' "$n" \
        "$(cat "$(dirname "$f")/microvolts" 2>/dev/null)" ;;
    esac
done

echo
echo "  current params:"
for p in /sys/module/intel_skl_int3472_tps68470/parameters/*; do
    [ -f "$p" ] && printf '    %-16s %s\n' "$(basename "$p")" "$(cat "$p")"
done
