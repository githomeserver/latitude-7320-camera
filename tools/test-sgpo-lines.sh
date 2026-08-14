#!/bin/bash
# Retest the standing "never drive tps68470-gpio 7, 8, 9" warning.
#
# THE DISPUTE. This project's notes say driving those lines wedges the PMIC
# until a reboot: regulator_bulk_enable then fails -EREMOTEIO and every rail
# reads "unknown". Charles Drolet drives 7, 8 and 9 freely on the same model
# and uses 9 as the rear camera's reset. One of those is wrong, or it is
# configuration-dependent - and the warning is the reason line 9 looked
# dangerous, so it matters for what gets said upstream about the rear camera.
#
# gpioinfo names them: 7 = s_enable, 8 = s_idle, 9 = s_resetn. They are backed
# by TPS68470_REG_SGPO rather than the ordinary GPIO register, which is the
# plausible mechanism for them behaving differently.
#
# METHOD. One line at a time, one polarity at a time, with a full health check
# after each. The health check is the point: a wedged PMIC is not visible from
# the gpio layer at all, only from a rail that will no longer come up. So each
# step actually powers the camera, which is what calls regulator_bulk_enable.
#
# Aborts the moment health fails, so the first bad line is identified rather
# than three of them being driven and the damage attributed to the last.
#
# RECOVERY IF IT WEDGES: reboot. Nothing here is persistent.
#
# Run as root:  sudo ./test-sgpo-lines.sh
#          or:  sudo ./test-sgpo-lines.sh 9      to test a single line

set -u

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

# DO NOT rename this back to LINES. LINES is a bash special variable holding
# the terminal height, and with `checkwinsize` on - the default since bash 5.0
# - bash overwrites it after every external command completes. An earlier
# version used LINES and worked perfectly when piped, then on a real terminal
# silently became the window height (61) the moment the baseline health check
# ran `cam`. The loop then tried to drive line 61 and the script reported a
# confident PASS having driven nothing. COLUMNS has the same problem.
TARGET_LINES="${*:-7 8 9}"

# Say what was actually received, and refuse anything unexpected rather than
# skipping it and concluding from zero measurements.
echo "invoked with argc=$# argv=[$*] -> testing lines: [$TARGET_LINES]"
echo

for l in $TARGET_LINES; do
    case "$l" in
        7|8|9) ;;
        *) echo "ERROR: '$l' is not one of the disputed lines 7/8/9." >&2
           echo "Refusing to run rather than skipping it and reporting success." >&2
           exit 1 ;;
    esac
done

# Counts line/polarity combinations actually driven. The verdict is gated on
# this being non-zero.
tested=0

CHIP=""
for c in /dev/gpiochip*; do
    case "$(gpiodetect 2>/dev/null | grep "$(basename "$c")" || true)" in
        *tps68470*) CHIP="$(basename "$c")" ;;
    esac
done
[ -n "$CHIP" ] || { echo "ERROR: no tps68470 gpiochip found" >&2; exit 1; }

# --- health: can the rails still be brought up? -----------------------------
# Reading regulator state is necessary but not sufficient - a wedged PMIC shows
# up when something tries to ENABLE a rail. Opening the camera does exactly
# that, so it is the real probe.
health() {
    local bad=0 n s
    for d in /sys/class/regulator/regulator.*; do
        n="$(cat "$d/name" 2>/dev/null)" || continue
        case "$n" in
            CORE|ANA|VCM|VIO|VSIO|AUX1|AUX2)
                s="$(cat "$d/state" 2>/dev/null)"
                case "$s" in
                    enabled|disabled|"") ;;
                    *) echo "      rail $n reads '$s'"; bad=1 ;;
                esac ;;
        esac
    done
    timeout 60 cam -c1 --capture=1 >/dev/null 2>&1 || bad=1
    return $bad
}

echo "== baseline health before touching anything =="
if health; then
    pass "rails sane and the camera powers up"
else
    fail "already unhealthy before the test - reboot and rerun"
    exit 1
fi
echo

for line in $TARGET_LINES; do
    label="$(gpioinfo -c "$CHIP" | grep -E "^\s*line\s+$line:" | awk '{print $3}')"
    echo "== line $line $label =="

    if gpioinfo -c "$CHIP" | grep -E "^\s*line\s+$line:" | grep -qE 'used|consumer='; then
        info "claimed by a driver - skipping, cannot drive it and should not try"
        echo
        continue
    fi

    for logical in 0 1; do
        printf '  driving %s=%s ... ' "$line" "$logical"
        gpioset -c "$CHIP" "$line=$logical" &
        pid=$!
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            printf '\033[31mgpioset refused\033[0m\n'
            continue
        fi
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        sleep 0.5

        tested=$((tested + 1))
        if health; then
            printf '\033[32mreleased, still healthy\033[0m\n'
        else
            printf '\033[31mPMIC WEDGED\033[0m\n'
            echo
            fail "line $line at logical $logical wedged the PMIC"
            info "the standing warning is RIGHT, at least for this line/polarity"
            info "rails will not come up again until reboot - stopping here"
            echo
            dmesg | tail -15 | sed 's/^/    /'
            exit 2
        fi
    done
    echo
done

echo "== verdict =="
if [ "$tested" -eq 0 ]; then
    fail "NOTHING WAS TESTED - no line was driven, so there is no result here"
    info "Do not record this as the warning failing to reproduce."
    exit 1
fi
pass "drove $tested line/polarity combination(s) across ${TARGET_LINES// /, } with no ill effect"
info "On this unit, in this configuration, the warning does not reproduce."
info "That matches Charles, who drives these lines freely on the same model."
echo
info "State it no more strongly than that. WHY the original observation"
info "happened is unknown: it was a different physical unit, and the rail and"
info "driver state at the time were not recorded. Do not attribute it to"
info "rail_map or anything else without evidence - that is the same mistake"
info "as the retracted EGL mechanism. 'Does not reproduce here' is the finding."
