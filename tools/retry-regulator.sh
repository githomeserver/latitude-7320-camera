#!/bin/bash
# Diagnostic: the tps68470-regulator cell failed its one probe with
#   "error -ENOENT: getting tps68470-clk"
# yet the tps68470-clk device is bound. If the clkdev simply was not registered
# yet at that moment, binding the regulator now will just work - which proves a
# probe-ordering race rather than a wrong board-data entry.
#
# -ENOENT is not -EPROBE_DEFER, so the kernel never retries on its own.
#
# Run as root:  sudo ./retry-regulator.sh

set -u
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

MARK="$(date '+%Y-%m-%d %H:%M:%S')"
REGDRV=/sys/bus/platform/drivers/tps68470-regulator

echo "== before =="
printf '  tps68470-clk bound:       %s\n' \
    "$([ -e /sys/bus/platform/devices/tps68470-clk/driver ] && echo yes || echo no)"
printf '  tps68470-regulator bound: %s\n' \
    "$([ -e /sys/bus/platform/devices/tps68470-regulator/driver ] && echo yes || echo no)"

echo
echo "== retrying the regulator bind =="
if echo tps68470-regulator > "$REGDRV/bind" 2>/dev/null; then
    echo "  bind succeeded -> it was an ordering race, not bad board data"
else
    echo "  bind failed (see log below)"
fi
sleep 1

echo
echo "== kernel log since retry =="
journalctl -k --no-pager --since "$MARK" | \
    grep -iE 'tps68470|regulator|ov8856|ov5678' | sed 's/^/  /' || echo "  (nothing)"

echo
echo "== regulators now registered =="
found=0
for n in /sys/class/regulator/*/name; do
    [ -f "$n" ] || continue
    case "$(cat "$n")" in
        CORE|ANA|VCM|VIO|VSIO|AUX1|AUX2)
            d="$(dirname "$n")"
            printf '  %-6s %8s uV  state=%s\n' "$(cat "$n")" \
                "$(cat "$d/microvolts" 2>/dev/null)" "$(cat "$d/state" 2>/dev/null)"
            found=1 ;;
    esac
done
[ "$found" = 1 ] || echo "  (none - regulator cell still not probed)"

echo
echo "== retrying the rear sensor (ov8856) =="
if [ -e /sys/bus/i2c/drivers/ov8856 ]; then
    echo i2c-OVTI8856:00 > /sys/bus/i2c/drivers/ov8856/unbind 2>/dev/null
    sleep 1
    echo i2c-OVTI8856:00 > /sys/bus/i2c/drivers/ov8856/bind 2>/dev/null
    sleep 2
    printf '  ov8856 bound: %s\n' \
        "$([ -e /sys/bus/i2c/devices/i2c-OVTI8856:00/driver ] && echo YES || echo no)"
    journalctl -k --no-pager --since "$MARK" | grep -i ov8856 | sed 's/^/  /' || true
else
    echo "  ov8856 driver not registered"
fi

echo
echo "== subdevs / media nodes (expected: none yet, IPU6 is not bound) =="
ls /sys/class/video4linux/ 2>/dev/null | sed 's/^/  /' || echo "  (none)"
