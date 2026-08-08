#!/bin/bash
# Load the ov5678 driver and see whether the front sensor answers on i2c.
#
# This is the Phase C milestone: if the chip id reads back, then the rail map,
# the reset/powerdown pins and the 19.2 MHz clock are all correct. If it does
# not, the failure is in one of those three and the sweep below narrows it.
#
# Safe to repeat: unlike the INT3472 probe, binding this driver does not
# consume any one-shot ACPI state, so it can be unloaded and reloaded freely.
#
# Run as root:  sudo ./test-sensor.sh [key=value ...]
#   e.g.        sudo ./test-sensor.sh expect_chip_id=0 reset_us=5000

set -u

USER_HOME="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
BUILD="${OV5678_BUILD_DIR:-${USER_HOME:-$HOME}/.cache}/ov5678-sensor-build"
KO="$BUILD/ov5678.ko"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
[ -f "$KO" ] || { echo "ERROR: $KO not built. Run tools/build.sh sensor" >&2; exit 1; }

MARK="$(date '+%Y-%m-%d %H:%M:%S')"

echo "== preconditions =="
printf '  i2c-OVTI5678:00 present:   %s\n' \
    "$([ -e /sys/bus/i2c/devices/i2c-OVTI5678:00 ] && echo yes || echo NO)"
printf '  tps68470-gpio bound:       %s\n' \
    "$([ -e /sys/bus/platform/devices/tps68470-gpio/driver ] && echo yes || echo NO)"
printf '  tps68470-regulator bound:  %s\n' \
    "$([ -e /sys/bus/platform/devices/tps68470-regulator/driver ] && echo yes || echo NO)"
printf '  int3472 gpio pin params:   front_reset=%s front_powerdown=%s rail_map=%s\n' \
    "$(cat /sys/module/intel_skl_int3472_tps68470/parameters/front_reset 2>/dev/null)" \
    "$(cat /sys/module/intel_skl_int3472_tps68470/parameters/front_powerdown 2>/dev/null)" \
    "$(cat /sys/module/intel_skl_int3472_tps68470/parameters/rail_map 2>/dev/null)"

echo
echo "== loading ov5678 =="
rmmod ov5678 2>/dev/null
if ! insmod "$KO" "$@"; then
    echo "ERROR: insmod failed" >&2
    exit 1
fi
echo "  inserted with: ${*:-<defaults>}"
sleep 2

echo
echo "== kernel log =="
journalctl -k --no-pager --since "$MARK" | grep -i 'ov5678' | sed 's/^/  /' || echo "  (nothing)"

echo
echo "== result =="
if [ -e /sys/bus/i2c/devices/i2c-OVTI5678:00/driver ]; then
    echo "  BOUND - the sensor answered on i2c."
    echo "  Power sequencing, rail map and reset/powerdown pins are all correct."
else
    echo "  not bound - the sensor did not answer."
    echo
    echo "  Narrow it down, cheapest first:"
    echo "   1. rail voltages are live but maybe mapped to the wrong supply:"
    echo "        sudo $0 expect_chip_id=0"
    echo "      then check whether the rails actually enabled:"
    for n in /sys/class/regulator/*/name; do
        [ -f "$n" ] || continue
        case "$(cat "$n")" in
            CORE|ANA|VSIO) d="$(dirname "$n")"
                printf '        %-5s %8s uV  state=%s\n' "$(cat "$n")" \
                    "$(cat "$d/microvolts" 2>/dev/null)" \
                    "$(cat "$d/state" 2>/dev/null)" ;;
        esac
    done
    echo "   2. wrong reset/powerdown pins. Sweep the tps68470 gpiochip directly"
    echo "      with gpioset (no reboot needed) - see README."
    echo "   3. wrong rail map: set rail_map=1 in the int3472 module and reboot."
fi

echo
echo "== regulator states after the attempt =="
for n in /sys/class/regulator/*/name; do
    [ -f "$n" ] || continue
    case "$(cat "$n")" in
        CORE|ANA|VCM|VIO|VSIO|AUX1|AUX2)
            d="$(dirname "$n")"
            printf '  %-5s %8s uV  state=%-8s users=%s\n' "$(cat "$n")" \
                "$(cat "$d/microvolts" 2>/dev/null)" \
                "$(cat "$d/state" 2>/dev/null)" \
                "$(cat "$d/num_users" 2>/dev/null)" ;;
    esac
done
