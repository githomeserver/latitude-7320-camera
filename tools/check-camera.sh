#!/bin/bash
# Post-reboot check for the full stack: board data, sensor driver, ipu-bridge
# entry, media graph, libcamera.
#
# Read-only, no root needed.

set -u

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

echo "== modules in use =="
for m in intel_skl_int3472_tps68470 ov5675 ipu_bridge; do
    n="$(modinfo -n "${m//_/-}" 2>/dev/null || modinfo -n "$m" 2>/dev/null)"
    case "$n" in
        *updates/dkms*) pass "$m -> $n" ;;
        "")             fail "$m not found" ;;
        *)              fail "$m -> $n (not our build)" ;;
    esac
done

echo
echo "== Phase A: power =="
[ -e /sys/bus/i2c/devices/i2c-INT3472:07/driver ] \
    && pass "INT3472 bound" || fail "INT3472 not bound"
n=0
for f in /sys/class/regulator/*/name; do
    [ -f "$f" ] || continue
    case "$(cat "$f")" in CORE|ANA|VCM|VIO|VSIO|AUX1|AUX2) n=$((n + 1)) ;; esac
done
[ "$n" -eq 7 ] && pass "all 7 rails registered" || fail "$n/7 rails"

echo
echo "== Phase C: sensor =="
drv=""
[ -e /sys/bus/i2c/devices/i2c-OVTI5678:00/driver ] && \
    drv="$(basename "$(readlink -f /sys/bus/i2c/devices/i2c-OVTI5678:00/driver)")"
case "$drv" in
    ov5675) pass "OVTI5678 bound to ov5675" ;;
    "")     fail "OVTI5678 has no driver bound" ;;
    *)      fail "OVTI5678 bound to '$drv', expected ov5675" ;;
esac

echo
echo "== Phase B: ipu-bridge =="
if journalctl -k -b 0 --no-pager 2>/dev/null | grep -q 'Found supported sensor OVTI5678'; then
    pass "ipu-bridge recognised OVTI5678"
else
    fail "ipu-bridge did not recognise OVTI5678"
fi
info "$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -o 'Connected [0-9]* cameras' | tail -1)"

echo
echo "== media graph =="
if [ -e /dev/media0 ]; then
    pass "/dev/media0 exists"
    if command -v media-ctl >/dev/null 2>&1; then
        ents="$(media-ctl -p -d /dev/media0 2>/dev/null | grep -oE '^- entity [0-9]+: [^(]*' | sed 's/^- entity [0-9]*: //' | grep -iE 'ov5675|ov8856' || true)"
        if [ -n "$ents" ]; then
            pass "sensor entity in graph:"
            echo "$ents" | sed 's/^/          /'
        else
            fail "no sensor entity in the media graph"
        fi
    fi
else
    fail "/dev/media0 missing"
fi

echo
echo "== libcamera =="
if command -v cam >/dev/null 2>&1; then
    cam -l 2>&1 | sed 's/^/  /'
else
    info "cam not installed (libcamera-tools)"
fi

echo
echo "== kernel log =="
journalctl -k -b 0 --no-pager 2>/dev/null \
    | grep -iE 'int3472|tps68470|ov5675|ov5678|ipu6|ipu-bridge' \
    | grep -viE 'Modules linked in' | sed 's/^/  /' | tail -25
