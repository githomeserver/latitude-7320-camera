#!/bin/bash
# Print the v4l2loopback device node, or fall back to /dev/video0.
#
# WHY THIS EXISTS
#
# Nothing pins v4l2loopback's device number, so it takes the first free one -
# which depends on whether it loads before or after the IPU6 creates its 64 raw
# ISYS nodes. On this machine it wins and lands on /dev/video0. On a machine
# where the IPU6 gets there first it lands on /dev/video64, and every tool here
# that hardcodes /dev/video0 then talks to a raw sensor node instead: the
# producer writes nowhere useful, the loopback never gets a format, and browsers
# skip it because a v4l2loopback with no producer has nothing to negotiate.
# Reported as issue #2.
#
# Matched on the driver name rather than the card label, since the label is a
# module parameter someone may well change.
set -eu
for d in /dev/video*; do
    [ -e "$d" ] || continue
    if [ "$(v4l2-ctl -d "$d" --info 2>/dev/null | awk -F': ' '/Driver name/{print $2; exit}')" = "v4l2 loopback" ]; then
        echo "$d"
        exit 0
    fi
done
echo "/dev/video0"
exit 1
