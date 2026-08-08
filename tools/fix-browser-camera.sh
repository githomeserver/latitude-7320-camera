#!/bin/bash
# Point v4l2-relayd at libcamera instead of Intel's proprietary CamHAL.
#
# WHY
#
# Browsers, Zoom and webcamtests.com all open a plain V4L2 device. The IPU6's
# own capture nodes (/dev/video1..video64) are raw Bayer sinks and cannot serve
# that, which is why Firefox lists dozens of dead "ipu6" entries. The one node
# that is meant to work is /dev/video0, "Intel MIPI Camera", a v4l2loopback
# device fed by v4l2-relayd.
#
# v4l2-relayd was configured with VIDEOSRC=icamerasrc, Intel's closed CamHAL.
# That HAL has no tuning data for this sensor - it falls back to an AR0234
# tuning file and then fails to configure the stream, in a retry loop:
#
#   CamHAL[INF] aiqb file name AR0234_TGL_10bits.aiqb
#   CamHAL[ERR] Input stream was missing
#   CamHAL[ERR] @configure, analyzeStream failed
#   CamHAL[ERR] failed to config streams.
#
# So the loopback device exists but nothing ever writes frames into it, which
# is exactly the "video track is paused" / spinner-forever symptom.
#
# libcamera drives this sensor correctly, so use libcamerasrc instead. That
# fixes every V4L2 consumer at once, with no per-browser flags.
#
# Run as root:  sudo ./fix-browser-camera.sh
#               sudo ./fix-browser-camera.sh revert

set -eu

CONF=/etc/v4l2-relayd.d/default.conf
BAK="$CONF.before-libcamera"
DROPIN_DIR=/etc/systemd/system/v4l2-relayd@.service.d
DROPIN="$DROPIN_DIR/10-dma-heap.conf"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

if [ "${1:-apply}" = "revert" ]; then
    if [ -f "$BAK" ]; then
        cp -f "$BAK" "$CONF"
        echo "restored $CONF from $BAK"
    else
        echo "no backup at $BAK, editing VIDEOSRC back to icamerasrc"
        sed -i 's|^VIDEOSRC=.*|VIDEOSRC=icamerasrc|' "$CONF"
    fi
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart v4l2-relayd.service
    exit 0
fi

# The unit sandbox only permits char-drm, char-media, char-intel-ipu6-psys,
# char-psys and char-video4linux. libcamera's software ISP needs a dma-buf
# provider, and /dev/dma_heap/system is char major 248 - outside all of those.
# Without it: "Could not open any dma-buf provider" -> "Failed to create
# software ISP, disabling software debayering", so the pipeline can only carry
# raw Bayer and never produces the YUY2 the relay asks for.
echo "== allowing dma-buf providers in the service sandbox =="
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<'EOF'
[Service]
# libcamera's software ISP needs a dma-buf heap; the stock DeviceAllow list
# does not cover /dev/dma_heap/system (char 248) or /dev/udmabuf (char 10:259).
DeviceAllow=/dev/dma_heap/system rw
DeviceAllow=/dev/udmabuf rw
EOF
cat "$DROPIN" | sed 's/^/  /'
systemctl daemon-reload

echo "== current config =="
cat "$CONF" | sed 's/^/  /'

[ -f "$BAK" ] || cp -a "$CONF" "$BAK"
echo
echo "  backup: $BAK"

# videoconvert + videoscale are needed because libcamerasrc negotiates the
# sensor's native size (2560x1600 here), not the 1280x720 the relay asks for.
sed -i 's|^VIDEOSRC=.*|VIDEOSRC=libcamerasrc ! videoconvert ! videoscale|' "$CONF"

echo
echo "== new config =="
cat "$CONF" | sed 's/^/  /'

echo
echo "== restarting v4l2-relayd =="
systemctl restart v4l2-relayd.service
sleep 4
systemctl is-active v4l2-relayd@default.service || true

echo
echo "== recent log =="
journalctl -u 'v4l2-relayd*' --since '30 seconds ago' --no-pager 2>/dev/null \
    | grep -viE 'aiqb file name' | tail -15 | sed 's/^/  /'

echo
echo "Now verify frames actually reach /dev/video0:"
echo "  gst-launch-1.0 -q v4l2src device=/dev/video0 ! videoconvert ! fakesink num-buffers=10"
echo "Then retry the browser."
