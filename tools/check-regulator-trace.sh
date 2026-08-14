#!/bin/bash
# Control test for tools/test-suspend-rails.sh.
#
# That script concludes "front-only board data is clear" from a SILENT
# regulator trace across a suspend. But silence has two causes:
#
#   1. no regulator was enabled          <- the finding
#   2. the tracepoints never recorded    <- no finding at all, just a dead probe
#
# They are indistinguishable from the output. So before trusting the silence,
# show that this instrument DOES produce events when rails are genuinely
# brought up - by opening the camera, which must power VSIO/AUX1/AUX2.
#
# An instrument that cannot be made to fire has not measured anything.
#
# Run as root:  sudo ./check-regulator-trace.sh

set -u

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

TR=""
for d in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    [ -d "$d/events/regulator" ] && { TR="$d"; break; }
done
[ -n "$TR" ] || { echo "ERROR: no regulator tracepoints at all" >&2; exit 1; }

echo "== arming regulator tracepoints ($TR) =="
echo 0 > "$TR/tracing_on"
echo    > "$TR/trace"
echo 1 > "$TR/events/regulator/enable"
echo 1 > "$TR/tracing_on"

echo
echo "== triggering a known rail enable: opening the camera =="
# Capturing forces the sensor's power sequence: ov5675's runtime-PM resume
# calls regulator_bulk_enable on avdd/dvdd/dovdd. If the tracepoints work,
# this cannot be silent.
timeout 60 cam -c1 --capture=2 >/dev/null 2>&1
rc=$?
echo "   cam exited $rc"
sleep 1
echo 0 > "$TR/tracing_on"

echo
echo "== events recorded =="
n="$(grep -cE 'regulator_(enable|disable)' "$TR/trace" 2>/dev/null || true)"
grep -E 'regulator_(enable|disable)' "$TR/trace" 2>/dev/null | head -30 | sed 's/^/  /'

echo
if [ "${n:-0}" -gt 0 ]; then
    printf '  \033[32mINSTRUMENT VALIDATED\033[0m  %s event(s) - the tracepoints do fire.\n' "$n"
    echo "  A SILENT trace across suspend is therefore a real negative result."
else
    printf '  \033[31mINSTRUMENT DEAD\033[0m  the camera was powered and nothing was recorded.\n'
    echo "  The suspend test measured nothing. Do NOT report its silence as a"
    echo "  finding - fix the tracing first."
fi
