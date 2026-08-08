#!/bin/bash
# Post-reboot check: did the board data bind on a clean boot, and did the
# clk/regulator/gpio cells all come up without hand-binding?
#
# Read-only. No root needed (journalctl -k works via the adm group).

set -u

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

echo "== which module is loaded =="
if [ -d /sys/module/intel_skl_int3472_tps68470/parameters ]; then
    pass "ours (has module parameters)"
    for p in /sys/module/intel_skl_int3472_tps68470/parameters/*; do
        [ -f "$p" ] && info "$(basename "$p") = $(cat "$p")"
    done
else
    fail "in-tree module is loaded, not ours - DKMS install did not take"
fi

echo
echo "== int3472 probe =="
[ -e /sys/bus/i2c/devices/i2c-INT3472:07/driver ] \
    && pass "i2c-INT3472:07 bound" || fail "i2c-INT3472:07 not bound"

if journalctl -k -b 0 --no-pager 2>/dev/null | grep -q 'No board-data found'; then
    fail "still reporting 'No board-data found'"
else
    pass "no 'No board-data found'"
fi

echo
echo "== mfd cells =="
for c in tps68470-clk tps68470-regulator tps68470-gpio; do
    [ -e "/sys/bus/platform/devices/$c/driver" ] \
        && pass "$c bound" || fail "$c NOT bound"
done

if journalctl -k -b 0 --no-pager 2>/dev/null | grep -q 'getting tps68470-clk'; then
    fail "clk/regulator ordering problem reproduced at boot"
else
    pass "no 'getting tps68470-clk' error"
fi

echo
echo "== regulators =="
n=0
for f in /sys/class/regulator/*/name; do
    [ -f "$f" ] || continue
    case "$(cat "$f")" in
        CORE|ANA|VCM|VIO|VSIO|AUX1|AUX2)
            d="$(dirname "$f")"
            info "$(printf '%-5s %8s uV  state=%s' "$(cat "$f")" \
                "$(cat "$d/microvolts" 2>/dev/null)" "$(cat "$d/state" 2>/dev/null)")"
            n=$((n + 1)) ;;
    esac
done
[ "$n" -eq 7 ] && pass "all 7 rails registered" || fail "$n/7 rails registered"

echo
echo "== sensor i2c clients (Phase A success signal) =="
for d in i2c-OVTI5678:00 i2c-OVTI8856:00; do
    if [ -e "/sys/bus/i2c/devices/$d" ]; then
        # readlink -f on a missing link echoes the path back, so test -e first
        # rather than reporting a bound driver literally named "driver".
        if [ -e "/sys/bus/i2c/devices/$d/driver" ]; then
            drv="$(basename "$(readlink -f "/sys/bus/i2c/devices/$d/driver")")"
        else
            drv="none"
        fi
        pass "$d present (driver=$drv)"
    else
        fail "$d absent"
    fi
done

echo
echo "== IPU6 (expected: still unbound; we are deliberately not enabling it) =="
[ -e /sys/bus/pci/devices/0000:00:05.0/driver ] \
    && info "IPU6 IS bound - unexpected, the isys panic path is now reachable" \
    || info "IPU6 unbound, as intended"

echo
echo "== relevant kernel log =="
journalctl -k -b 0 --no-pager 2>/dev/null \
    | grep -iE 'int3472|tps68470|ov8856|ov5678' | sed 's/^/  /' || echo "  (none)"
