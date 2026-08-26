#!/bin/bash
# Why does a full-resolution pipeline fail to negotiate?
#
# bench-fullres.sh reported 2592x1944 as FAILED with a 0.11s runtime - that is
# an instant negotiation failure, not slow capture. This asks libcamera what it
# actually offers, then runs the pipeline and keeps the error.
#
# Run as root:  sudo ./diag-fullres.sh
set -u
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu
export LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera/ipa
export GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/../data/fullres-diag.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1
cleanup() { echo; echo "== restarting v4l2-relayd =="; systemctl start ov5678-ondemand.service 2>/dev/null || true; chown "${SUDO_USER:-root}" "$LOG" 2>/dev/null || true; }
trap cleanup EXIT
echo "== stopping v4l2-relayd =="
systemctl stop ov5678-ondemand.service
sleep 2

echo
echo "=========== sensor modes the kernel driver offers ==========="
for sd in /dev/v4l-subdev*; do
    if v4l2-ctl -d "$sd" --list-subdev-mbus-codes 0 2>/dev/null | grep -q .; then
        if v4l2-ctl -d "$sd" --list-ctrls 2>/dev/null | grep -q analogue_gain; then
            echo "-- $sd"
            v4l2-ctl -d "$sd" --list-subdev-framesizes pad=0,code=0x300d 2>/dev/null | head
            v4l2-ctl -d "$sd" --list-subdev-framesizes pad=0,code=0x3011 2>/dev/null | head
        fi
    fi
done

echo
echo "=========== what libcamera reports for the camera ==========="
timeout 60 cam -l 2>&1 | head -20
echo "--- stream formats/sizes:"
timeout 60 cam -c1 --list-controls 2>&1 | head -5
timeout 60 cam -c1 -I 2>&1 | grep -iE 'size|format|[0-9]{3,4}x[0-9]{3,4}' | head -25

echo
echo "=========== negotiation attempt at 2592x1944 ==========="
timeout 60 gst-launch-1.0 libcamerasrc \
    ! 'video/x-raw,width=2592,height=1944' \
    ! identity eos-after=5 ! fakesink sync=false 2>&1 | tail -20

echo
echo "=========== unconstrained (let libcamera choose) ==========="
timeout 90 gst-launch-1.0 -v libcamerasrc \
    ! identity eos-after=5 ! fakesink sync=false 2>&1 \
    | grep -iE 'caps|width|height|negotiat|error|warn' | head -20
