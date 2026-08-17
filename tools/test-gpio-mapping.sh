#!/bin/bash
# Reproduce Charles Drolet's GPIO mapping test on a second 7320 Detachable.
#
# Claim under test (GitHub issue #1): the OVTI5678 front sensor reset is
# tps68470-gpio line 5, active low; line 3 is inert; there is no powerdown pin.
#
# Method — the point is the control, not the positive result. The sensor probes
# fine with NO pin assigned, so "the camera works" proves nothing. What proves
# something is making the probe FAIL on demand: hold the candidate line
# physically low, reload ov5675, and see -EIO. A line that is really the reset
# can stop the sensor. A line that is not, cannot.
#
# Requires the module to be built with no pin assignment, so nothing else has
# claimed the lines (tools/provision-machine.sh sets that up).
#
# CAUTION: this touches lines 3 and 5 only. Lines 7, 8 and 9 are under a
# standing warning in the project notes (driving them wedged the PMIC until
# reboot). Charles reports driving them freely on the same model. That dispute
# is a SEPARATE test — do not fold it in here.
#
# Run as root:  sudo ./test-gpio-mapping.sh

set -u

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

# --- locate the TPS68470 gpiochip by label, never by number -----------------
# gpiochip numbering depends on probe order. Charles's gpiochip1 is not
# guaranteed to be ours.
CHIP=""
for c in /dev/gpiochip*; do
    lbl="$(gpiodetect 2>/dev/null | grep "$(basename "$c")" || true)"
    case "$lbl" in
        *tps68470*) CHIP="$(basename "$c")" ;;
    esac
done

if [ -z "$CHIP" ]; then
    echo "ERROR: no tps68470 gpiochip found. Chips present:" >&2
    gpiodetect >&2
    echo >&2
    echo "If only the SoC chip is listed, the INT3472 board data did not bind." >&2
    echo "Check: ls /sys/bus/i2c/devices/ | grep OVTI    (expect i2c-OVTI5678:00)" >&2
    exit 1
fi

echo "== tps68470 gpiochip: $CHIP =="
gpiodetect | grep "$CHIP"
echo

BOUND=/sys/bus/i2c/devices/i2c-OVTI5678:00/driver

# --- confirm the control condition: nothing has claimed the lines ----------
echo "== control condition: no pin assignment =="
for p in /sys/module/intel_skl_int3472_tps68470/parameters/*; do
    [ -f "$p" ] && printf '  %-18s %s\n' "$(basename "$p")" "$(cat "$p")"
done
busy="$(gpioinfo -c "$CHIP" 2>/dev/null | grep -cE 'used|consumer=' || true)"
if [ "${busy:-0}" -eq 0 ]; then
    pass "no lines claimed on $CHIP"
    echo
else
    # The drive test needs unassigned lines: a line the driver holds cannot be
    # driven by gpioset, so every trial would fail for the wrong reason. Rather
    # than emit a confusing false negative, switch to the check that IS
    # meaningful once a mapping is configured - that the board data lookup
    # actually resolved and the driver took the line it was told to.
    echo
    echo "== assigned configuration detected — drive test not applicable =="
    info "$busy line(s) claimed on $CHIP. gpioset cannot drive a held line, so"
    info "the reset-by-elimination test only works against an unassigned build."
    info "Verifying the assignment instead."
    echo
    gpioinfo -c "$CHIP" | grep -E 'used|consumer=' | sed 's/^/    /'
    echo

    # The upstream module has no front_reset parameter - the pin is compiled in
    # as 5. Fall back to that rather than reporting '?' and failing the check.
    want="$(cat /sys/module/intel_skl_int3472_tps68470/parameters/front_reset 2>/dev/null || echo 5)"
    [ -n "$want" ] || want=5
    if [ "$want" = "-1" ]; then
        fail "front_reset=-1 yet lines are claimed — something else holds them"
    elif gpioinfo -c "$CHIP" | grep -E "^\s*line\s+$want:" | grep -qE 'used|consumer='; then
        pass "front_reset=$want and line $want is claimed — the GPIO lookup resolved"
        gpioinfo -c "$CHIP" | grep -E "^\s*line\s+$want:" | sed 's/^/        /'
        info "active-low is the property to eyeball above; the board data sets it"
    else
        fail "front_reset=$want but line $want is NOT claimed — lookup did not resolve"
        info "that is the failure mode the dead 'powerdown' lookup had: silently unused"
    fi
    echo

    if [ -e "$BOUND" ]; then
        pass "front sensor bound with the reset assigned (mapping breaks nothing)"
    else
        fail "front sensor NOT bound — the assigned mapping broke a working camera"
    fi
    echo
    echo "For the mapping evidence itself, run this against an unassigned build"
    echo "(front_reset=-1). That result is what establishes which line is reset."
    exit 0
fi

# --- the test ---------------------------------------------------------------
# gpioset -l = --active-low, so "N=1" drives the pin PHYSICALLY LOW.
# Stated in physical terms below to avoid the inversion trap.
probe_with_line() {                  # $1 = line, $2 = physical level (low|high)
    local line="$1" want="$2" logical pid rc
    [ "$want" = "low" ] && logical=1 || logical=0

    # libgpiod 2.2 dropped '-m wait' (Charles is on an older build) and needs
    # -c to accept a numeric offset. gpioset blocks holding the line until
    # killed, which is what the old '-m wait' did.
    gpioset -l -c "$CHIP" "$line=$logical" &
    pid=$!
    sleep 0.4
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: gpioset exited immediately for $CHIP $line=$logical" >&2
        return 2
    fi

    # Assert the unload actually happened. Without this the test cannot tell
    # "the sensor probed" from "the driver never unbound, so the sysfs link
    # was still there from last time" - the two produce identical output.
    modprobe -r ov5675 2>/dev/null
    if [ -e "$BOUND" ] || lsmod | grep -q '^ov5675 '; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        echo "ERROR: ov5675 did not unload - result would be meaningless" >&2
        return 2
    fi

    # Clear the ring buffer so what prints below is THIS trial only. A silent
    # buffer after a reload is itself the success signal: a stock ov5675 logs
    # nothing when it identifies, and two lines when it does not.
    dmesg -C
    modprobe ov5675 2>/dev/null
    sleep 0.8
    if [ -e "$BOUND" ]; then rc=0; else rc=1; fi

    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return $rc
}

# Three trials per condition. One observation of a race-prone reload is not a
# result, and a flapping line would otherwise read as a clean verdict.
TRIALS=3

report() {                           # $1 = line, $2 = physical, $3 = expectation
    local line="$1" phys="$2" expect="$3" got i agree=0 fresh
    printf '  line %-2s physically %-4s (expect %s)\n' "$line" "$phys" "$expect"
    for i in $(seq 1 $TRIALS); do
        if probe_with_line "$line" "$phys"; then got="probes"
        elif [ $? -eq 2 ]; then
            printf '    trial %d: \033[31mHARNESS ERROR - aborting\033[0m\n' "$i"
            return 1
        else got="fails"
        fi
        [ "$got" = "$expect" ] && agree=$((agree + 1))
        fresh="$(dmesg | grep -c 'ov5675' || true)"
        printf '    trial %d: %-6s  (%s fresh ov5675 kernel line(s))\n' "$i" "$got" "$fresh"
        dmesg | grep 'ov5675' | sed 's/^/              /'
    done
    printf '    -> %d/%d agree with expectation  ' "$agree" "$TRIALS"
    [ "$agree" -eq "$TRIALS" ] && printf '\033[32mOK\033[0m\n' || printf '\033[31mNOT CONCLUSIVE\033[0m\n'
    echo
}

echo "== line 5: the claimed reset =="
info "active-low reset: held low the sensor must FAIL to identify"
report 5 low  fails
report 5 high probes

echo "== line 3: the control, claimed inert =="
info "if 3 were the reset, holding it low would break the probe too"
report 3 low  probes
report 3 high probes

echo "== baseline: no line driven =="
modprobe -r ov5675 2>/dev/null; modprobe ov5675 2>/dev/null; sleep 0.6
[ -e /sys/bus/i2c/devices/i2c-OVTI5678:00/driver ] \
    && pass "sensor probes with nothing driven (expected — this is why a wrong map hid)" \
    || fail "sensor does NOT probe undriven; a line may be stuck from a previous run"

echo
echo "Verdict: reset is line 5 only if line 5 low FAILS and line 3 low PROBES."
echo "Anything else means the mapping is still not established — say so."
