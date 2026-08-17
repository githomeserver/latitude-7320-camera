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

# The standalone out-of-tree ov5678.ko this script was written against no
# longer exists. The sensor is driven by ov5675 with the OVTI5678 ACPI id
# added (upstream patch 2/3), shipped by DKMS package camera-dell7320.
MOD=ov5675

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
modinfo -n "$MOD" >/dev/null 2>&1 || { echo "ERROR: $MOD not installed. Run tools/dkms-install.sh" >&2; exit 1; }
if ! (zstdcat "$(modinfo -n $MOD)" 2>/dev/null || cat "$(modinfo -n $MOD)") | strings | grep -q OVTI5678; then
    echo "ERROR: the installed $MOD is the STOCK one - it has no OVTI5678 id and will never bind." >&2
    echo "       Install the DKMS package: sudo dkms install camera-dell7320/0.4 -k \$(uname -r)" >&2
    exit 1
fi

MARK="$(date '+%Y-%m-%d %H:%M:%S')"

echo "== preconditions =="
printf '  i2c-OVTI5678:00 present:   %s\n' \
    "$([ -e /sys/bus/i2c/devices/i2c-OVTI5678:00 ] && echo yes || echo NO)"
printf '  tps68470-gpio bound:       %s\n' \
    "$([ -e /sys/bus/platform/devices/tps68470-gpio/driver ] && echo yes || echo NO)"
printf '  tps68470-regulator bound:  %s\n' \
    "$([ -e /sys/bus/platform/devices/tps68470-regulator/driver ] && echo yes || echo NO)"
# The upstream module has no parameters - reset pin and rails are compiled in.
# Only the old development module exposed these, so report which one is loaded.
if [ -e /sys/module/intel_skl_int3472_tps68470/parameters/front_reset ]; then
    printf '  int3472: DEVELOPMENT module, front_reset=%s front_powerdown=%s rail_map=%s\n' \
        "$(cat /sys/module/intel_skl_int3472_tps68470/parameters/front_reset 2>/dev/null)" \
        "$(cat /sys/module/intel_skl_int3472_tps68470/parameters/front_powerdown 2>/dev/null)" \
        "$(cat /sys/module/intel_skl_int3472_tps68470/parameters/rail_map 2>/dev/null)"
else
    printf '  int3472: upstream board data (no parameters); reset hardcoded to tps68470-gpio 5\n'
fi

echo
echo "== loading $MOD =="
modprobe -r "$MOD" 2>/dev/null
if ! modprobe "$MOD" "$@"; then
    echo "ERROR: modprobe $MOD failed" >&2
    exit 1
fi
echo "  loaded $(modinfo -n $MOD) with: ${*:-<defaults>}"
sleep 2

echo
echo "== kernel log =="
journalctl -k --no-pager --since "$MARK" | grep -iE 'ov5675|ov5678|OVTI5678' | sed 's/^/  /' || echo "  (nothing)"

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
    echo "   3. wrong rails. The upstream board data hardcodes VSIO/AUX1/AUX2;"
    echo "      note INT3472 probes ONCE per boot, so any board-data change"
    echo "      needs a reboot - unbind/bind cannot re-probe it."
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
