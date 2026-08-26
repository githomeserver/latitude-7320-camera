#!/bin/bash
# Demosaic one full-res raw frame both ways and write a side-by-side PNG.
# Stops v4l2-relayd for exclusive raw access and restarts it afterwards.
#
# Point the camera at something with SATURATED COLOUR - the Kmart swatch
# poster is ideal, or anything with strong blues and reds. Good light: this
# reads the unbinned mode, so roughly a quarter the light per pixel.
#
#   sudo ./rgbir-proof.sh        channel assignment only
#   sudo ./rgbir-proof.sh 1.0    also subtract IR from R,G,B (uncalibrated)
#
# Output: /tmp/rgbir-proof.png  (left = now, right = RGB-IR)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
cleanup() { echo; echo "== restarting v4l2-relayd =="; systemctl start ov5678-ondemand.service 2>/dev/null || true; }
trap cleanup EXIT
echo "== stopping v4l2-relayd =="
systemctl stop ov5678-ondemand.service
sleep 2
echo
python3 "$HERE/rgbir-proof.py" "$@"
for f in /tmp/rgbir-proof.png /tmp/rgbir-asnow.png /tmp/rgbir-fixed.png \
         /tmp/rgbir-raw.bin /tmp/rgbir-raw.bin.txt; do
    [ -f "$f" ] && chown "${SUDO_USER:-root}" "$f" 2>/dev/null
done
