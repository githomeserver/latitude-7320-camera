#!/bin/bash
# Does the suspend regression Charles reported affect FRONT-ONLY board data?
#
# His report (2026-08-12): suspending the tablet brings the TPS68470 power
# rails UP and resuming brings them DOWN - inverted - costing battery on
# machines whose owners never use the camera. He argued board data should not
# be sent upstream until it is fixed.
#
# His own follow-up points at the VCM: while testing pin 9 the VCM failed to
# instantiate ("Error -13 runtime-resuming sensor, cannot instantiate VCM"),
# and with it absent the rails stayed down across suspend. The front module has
# no VCM (ACPI NVS L0VC=0; the VCM is the rear OV8856's, i2c 0x0c), so
# front-only board data should not reproduce it.
#
# If that holds, v2 of patch 1/3 can go as a front-only patch without owning
# the rear camera's bug. This script is what decides that.
#
# Run as root:  sudo ./test-suspend-rails.sh
#
# It really does suspend the machine, for 15 seconds, via the RTC alarm.

set -u

SECS="${SECS:-15}"
RAILS='CORE|ANA|VCM|VIO|VSIO|AUX1|AUX2'

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

snapshot() {
    for d in /sys/class/regulator/regulator.*; do
        n="$(cat "$d/name" 2>/dev/null)" || continue
        case "$n" in
            CORE|ANA|VCM|VIO|VSIO|AUX1|AUX2)
                printf '%-6s state=%-9s uV=%s\n' \
                    "$n" "$(cat "$d/state" 2>/dev/null)" \
                    "$(cat "$d/microvolts" 2>/dev/null)" ;;
        esac
    done | sort
}

# Enable counts are the real evidence. A rail can read "disabled" either side of
# a suspend while its refcount has been left incremented - the before/after
# state alone would miss exactly the bug being looked for.
summary() {
    if [ -r /sys/kernel/debug/regulator/regulator_summary ]; then
        grep -E "^ ?($RAILS)|use|open" \
            /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | head -20
    else
        echo "(debugfs regulator_summary unavailable - mount debugfs for refcounts)"
    fi
}

echo "== configuration under test =="
for p in /sys/module/intel_skl_int3472_tps68470/parameters/*; do
    [ -f "$p" ] && printf '  %-18s %s\n' "$(basename "$p")" "$(cat "$p")"
done
printf '  %-18s %s\n' "front ov5675" \
    "$([ -e /sys/bus/i2c/devices/i2c-OVTI5678:00/driver ] && echo bound || echo 'NOT bound')"
printf '  %-18s %s\n' "rear ov8856" \
    "$([ -e /sys/bus/i2c/devices/i2c-OVTI8856:00/driver ] && echo bound || echo 'NOT bound')"
printf '  %-18s %s\n' "dw9714 VCM" \
    "$(lsmod | grep -q '^dw9714 ' && echo 'LOADED - not a front-only test!' || echo 'not loaded')"
echo

echo "== before suspend =="
BEFORE="$(snapshot)"
echo "$BEFORE" | sed 's/^/  /'
echo "  -- refcounts --"
summary | sed 's/^/  /'
echo

# THE ACTUAL MEASUREMENT.
#
# A before/after snapshot cannot see this bug. Charles's symptom is rails UP
# during suspend and back DOWN on resume, so both snapshots read "disabled" and
# the diff says NO CHANGE whether or not the bug fired. The suspend window is
# precisely the interval userspace cannot observe.
#
# ftrace can: the regulator tracepoints keep recording while userspace is
# frozen, and the ring buffer survives the resume. Any regulator_enable on
# VSIO/AUX1/AUX2 between the suspend and resume entries is the bug, caught in
# the act.
TR=""
for d in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    [ -d "$d/events/regulator" ] && { TR="$d"; break; }
done

if [ -n "$TR" ]; then
    echo "== arming regulator tracepoints ($TR) =="
    echo 0 > "$TR/tracing_on"
    echo    > "$TR/trace"
    echo 1 > "$TR/events/regulator/enable"
    echo 1 > "$TR/tracing_on"
    echo "   regulator_enable / regulator_disable events armed"
else
    echo "== WARNING: no regulator tracepoints available =="
    echo "   Without these the suspend window is unobservable and a NO CHANGE"
    echo "   result below proves nothing about Charles's report."
fi
echo

dmesg -C
echo "== suspending for ${SECS}s (RTC wake) =="
rtcwake -m mem -s "$SECS" || { echo "ERROR: rtcwake failed" >&2; exit 1; }
sleep 2

if [ -n "$TR" ]; then
    echo 0 > "$TR/tracing_on"
fi

echo
echo "== after resume =="
AFTER="$(snapshot)"
echo "$AFTER" | sed 's/^/  /'
echo "  -- refcounts --"
summary | sed 's/^/  /'
echo

echo "== rail state diff across the cycle =="
if [ "$BEFORE" = "$AFTER" ]; then
    printf '  \033[32mNO CHANGE\033[0m - rails are in the same state as before suspend\n'
else
    printf '  \033[31mCHANGED\033[0m:\n'
    diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/    /'
fi

echo
echo "== regulator activity DURING the suspend window =="
if [ -n "$TR" ]; then
    n_ev="$(grep -cE 'regulator_(enable|disable)' "$TR/trace" 2>/dev/null || true)"
    if [ "${n_ev:-0}" -eq 0 ]; then
        printf '  \033[32mSILENT\033[0m - no regulator was enabled or disabled across the cycle\n'
        printf '  This is the result that clears front-only board data.\n'
    else
        printf '  \033[31m%s regulator event(s) recorded\033[0m - inspect before trusting 1/3:\n' "$n_ev"
        grep -E 'regulator_(enable|disable)' "$TR/trace" | head -40 | sed 's/^/    /'
    fi
    echo "  (full trace: $TR/trace)"
else
    printf '  \033[31mNOT MEASURED\033[0m - no tracepoints; this test did not answer the question\n'
fi

echo
echo "== kernel messages during suspend/resume =="
dmesg | grep -iE 'regulator|tps68470|ov5675|ov8856|int3472|vcm' | sed 's/^/  /' \
    || echo "  (none - clean cycle)"

echo
echo "== camera still works after resume? =="
if timeout 60 cam -l 2>/dev/null | grep -q 'Internal front camera'; then
    printf '  \033[32mPASS\033[0m  libcamera still enumerates the front camera\n'
else
    printf '  \033[31mFAIL\033[0m  camera gone after resume - that is its own bug, report it\n'
fi

echo
echo "Reading this: front-only board data is clear only if the trace above is"
echo "SILENT. The before/after rail diff is a secondary check - it catches a"
echo "leaked refcount, but it cannot see rails that go up during suspend and"
echo "come back down on resume, which is the reported symptom."
