#!/bin/bash
# Measure the OV5675's exposure and gain application delays, for the
# sensorDelays field of libcamera's camera_sensor_properties.cpp.
#
# Needs exclusive use of the sensor, so v4l2-relayd is stopped for the duration
# and restarted afterwards - the camera will be unavailable for a minute or so.
#
# Point the camera at a STATIC, EVENLY LIT scene. The measurement works by
# stepping exposure and watching which frame gets brighter, so anything moving
# in shot adds noise. A blank wall with the lights on is ideal.
#
# Run as root:  sudo ./measure-sensor-delays.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/../data/sensor-delays.log"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

mkdir -p "$(dirname "$LOG")"

cleanup() {
    echo
    echo "== restarting v4l2-relayd =="
    systemctl start v4l2-relayd.service 2>/dev/null || true
}
trap cleanup EXIT

echo "== stopping v4l2-relayd for exclusive sensor access =="
systemctl stop v4l2-relayd.service
sleep 2

echo
python3 "$HERE/measure-sensor-delays.py" 2>&1 | tee "$LOG"
chown --reference="$HERE" "$LOG" 2>/dev/null || true

echo
echo "transcript: $LOG"
