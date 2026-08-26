#!/bin/bash
# Determine whether the green cast is a Bayer-phase problem or an AWB problem.
# Stops v4l2-relayd for exclusive raw access, restarts it after.
#
# Point the camera at a flat, evenly lit surface (a white wall works).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/../data/bayer-order.log"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"
cleanup() { echo; echo "== restarting the camera pipeline =="; systemctl start ov5678-ondemand.service 2>/dev/null || true; }
trap cleanup EXIT
echo "== stopping the camera pipeline =="
systemctl stop ov5678-ondemand.service
sleep 2
echo
python3 "$HERE/check-bayer-order.py" 2>&1 | tee "$LOG"
chown --reference="$HERE" "$LOG" 2>/dev/null || true
