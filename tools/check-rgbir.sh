#!/bin/bash
# Test whether the front sensor is a 2x2 Bayer or a 4x4 RGB-IR mosaic.
# Stops v4l2-relayd for exclusive raw access and restarts it afterwards.
#
# POINT THE CAMERA AT SOMETHING STRONGLY COLOURED - a red or blue object
# filling much of the frame. A white wall proves nothing: on a neutral scene
# red and blue read alike, so the test cannot separate them.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/../data/rgbir.log"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"
cleanup() { echo; echo "== restarting v4l2-relayd =="; systemctl start v4l2-relayd.service 2>/dev/null || true; }
trap cleanup EXIT
echo "== stopping v4l2-relayd =="
systemctl stop v4l2-relayd.service
sleep 2
echo
python3 "$HERE/check-rgbir.py" 2>&1 | tee "$LOG"
chown --reference="$HERE" "$LOG" 2>/dev/null || true
