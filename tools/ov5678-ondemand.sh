#!/bin/bash
# Run the camera pipeline only while something is actually watching.
#
# WHY THIS EXISTS
#
# ov5678-camera.service holds the sensor open and runs the whole software ISP -
# RGB-IR pre-pass over 5 megapixels, denoise, shading, debayer - at 30 fps for
# as long as it is enabled. Measured: the SWIspWorker thread sits at 99.9% of a
# core indefinitely. On a fanless 9 W detachable that means the fan runs, the
# CPU sits near 100 C, and the battery drains, whether or not any application
# has the camera open. That is the cost of having replaced v4l2-relayd, which
# started on demand but throttled the pipeline to 1.3 fps.
#
# This gets both: the direct pipeline's frame rate, and idle silence.
#
# WHY A PLACEHOLDER IS NEEDED
#
# Polling for consumers cannot work on its own. With no producer attached the
# loopback has NO format - /sys/.../format reads empty - so a consumer fails
# negotiation and exits in about 3.5 MILLISECONDS ("not-negotiated (-4)").
# Openers read zero at every poll; no poll interval is short enough to see it.
#
# So something must always hold the device as a producer to keep a format on it.
# A black videotestsrc at 1 fps does that for well under 1% of a core, against
# the ~100% the real pipeline costs. This is the same trick v4l2-relayd used with
# its splash image, minus the relay that throttled everything to 1.3 fps.
#
# Consequence: an application that opens the camera cold sees black frames for a
# few seconds while the real pipeline starts. That is deliberate - it beats the
# alternative, which is the open failing outright.
#
# HOW IT DECIDES
#
# v4l2loopback exposes no consumer count, so openers are found by scanning
# /proc/*/fd for the loopback device and discounting the producer's own handle.
# Polling once a second costs nothing next to the pipeline it is gating.
#
# A grace period keeps the producer alive briefly after the last consumer
# leaves, so an application that closes and immediately reopens - browsers do
# this when switching cameras - does not pay the restart.
#
# Run as root; normally started by ov5678-ondemand.service.

set -u

LOOPBACK="${LOOPBACK:-/dev/video0}"
PRODUCER="${PRODUCER:-ov5678-camera.service}"
PLACEHOLDER="${PLACEHOLDER:-ov5678-placeholder.service}"
# 2s, not 1s. The scan costs ~96 ms of CPU (there is no cheap kernel signal -
# v4l2loopback exposes no consumer count and its sysfs is byte-identical with and
# without a consumer attached), so 1 Hz would burn 10% of a core to save 100%.
# 2 s costs 4.8% and adds at most two seconds before the producer is asked to
# start.
POLL="${POLL:-2}"
GRACE="${GRACE:-15}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

dev_id() {
    # major:minor, so a moved/renamed node is still matched correctly.
    stat -c '%t:%T' "$LOOPBACK" 2>/dev/null
}

producer_pid() {
    systemctl show -p MainPID --value "$PRODUCER" 2>/dev/null
}

# PIDs holding the loopback open, excluding the producer.
#
# One find(1), not a bash loop calling readlink per descriptor. The loop version
# forked thousands of processes a second and burned a full core - it cost more
# than the pipeline it was supposed to be saving.
consumers() {
    local ppid="$1"
    find /proc -maxdepth 3 -path '/proc/[0-9]*/fd/*' -lname "$LOOPBACK" \
         -printf '%h\n' 2>/dev/null \
      | sed 's|/proc/||; s|/fd$||' | sort -u | grep -vx "$ppid" | tr '\n' ' '
}

echo "watching $LOOPBACK, producer $PRODUCER, grace ${GRACE}s"

start_real() {
    systemctl stop "$PLACEHOLDER" 2>/dev/null
    systemctl start "$PRODUCER"
}

start_placeholder() {
    systemctl stop "$PRODUCER" 2>/dev/null
    systemctl start "$PLACEHOLDER"
}

# Begin idle: placeholder holds the format, real pipeline off.
start_placeholder
idle=0
running=""

while true; do
    ppid="$(producer_pid)"
    hpid="$(systemctl show -p MainPID --value "$PLACEHOLDER" 2>/dev/null)"
    c="$(consumers "$ppid" | tr ' ' '\n' | grep -vx "$hpid" | tr '\n' ' ')"

    if [ -n "${c// /}" ]; then
        idle=0
        if [ -z "$running" ]; then
            echo "consumer(s)${c} - starting the real pipeline"
            start_real
            running=1
        fi
    elif [ -n "$running" ]; then
        idle=$((idle + POLL))
        if [ "$idle" -ge "$GRACE" ]; then
            echo "idle ${idle}s - back to placeholder"
            start_placeholder
            running=""
            idle=0
        fi
    fi
    sleep "$POLL"
done
