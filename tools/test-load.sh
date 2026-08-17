#!/bin/bash
# OBSOLETE - DO NOT USE. Kept because the reasoning below is worth having.
#
# This swapped the int3472 tps68470 module at runtime to test board-data
# changes. That CANNOT WORK, and running it leaves the camera dead until you
# reboot.
#
# INT3472 probes exactly once per boot. skl_int3472_tps68470_probe() counts its
# consumers with for_each_acpi_consumer_dev(), which walks the global ACPI
# dependency list, and the first successful probe calls
# acpi_dev_clear_dependencies() -> acpi_scan_clear_dep(), which DELETES those
# entries. They are never recreated. So after unloading, the reload fails with
#
#   int3472-tps68470 i2c-INT3472:07: INT3472 seems to have no dependents
#
# and no amount of unbind/bind or modprobe brings it back. Confirmed the hard
# way on 2026-08-16.
#
# It is also obsolete for a second reason: the module no longer takes any
# parameters. DKMS package camera-dell7320 0.4 carries the upstream board data,
# which hardcodes reset on tps68470-gpio 5 and the VSIO/AUX1/AUX2 rails.
#
# To test a board-data change, use tools/test-patch1-isolated.sh, which builds
# from the patch and reboots.

set -u

cat >&2 <<'WARN'
REFUSING TO RUN. This tool cannot work and would leave the camera dead.

INT3472 can only probe once per boot - the ACPI _DEP entries are deleted by the
first successful probe, so reloading the module gets "INT3472 seems to have no
dependents" and nothing brings it back short of a reboot.

Use:  sudo tools/test-patch1-isolated.sh install    (then reboot)

See the header of this file for the full explanation.
WARN
exit 1

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
