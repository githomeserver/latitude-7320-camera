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

# The config path differs between installs. v4l2-relayd@.service reads
#   EnvironmentFile=/etc/default/v4l2-relayd          (always)
#   EnvironmentFile=-/etc/v4l2-relayd.d/%i.conf       (optional, per instance)
# The OEM image this was written against shipped the per-instance file; a stock
# Ubuntu install has only /etc/default/v4l2-relayd. Hardcoding the first made
# both scripts fail with "No such file or directory" on a clean machine while
# still reporting success for the steps that had run.
CONF=""
for c in /etc/v4l2-relayd.d/default.conf /etc/default/v4l2-relayd; do
    [ -f "$c" ] && CONF="$c"
done
[ -n "$CONF" ] || { echo "ERROR: no v4l2-relayd config found" >&2; exit 1; }
BAK="$CONF.before-libcamera"
DROPIN_DIR=/etc/systemd/system/v4l2-relayd@.service.d
DROPIN="$DROPIN_DIR/10-dma-heap.conf"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

if [ "${1:-apply}" = "revert" ]; then
    if [ -f "$BAK" ]; then
        cp -f "$BAK" "$CONF"
        echo "restored $CONF from $BAK"
    else
        # Do NOT guess. The OEM image shipped icamerasrc, but a stock Ubuntu
        # install ships videotestsrc, and writing the wrong one back leaves a
        # machine whose camera silently shows a test pattern.
        echo "no backup at $BAK - refusing to guess the original VIDEOSRC." >&2
        echo "Current value is:" >&2
        grep '^VIDEOSRC=' "$CONF" | sed 's/^/  /' >&2
        echo "Set it by hand: icamerasrc on the Dell OEM image, videotestsrc on stock Ubuntu." >&2
        exit 1
    fi
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    # Apply creates this, so revert must remove it - otherwise the relay keeps
    # starting at boot against a reverted config.
    rm -f /etc/systemd/system/v4l2-relayd.service.wants/v4l2-relayd@default.service
    rmdir /etc/systemd/system/v4l2-relayd.service.wants 2>/dev/null || true
    systemctl daemon-reload
    systemctl stop v4l2-relayd@default.service 2>/dev/null || true
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
echo "== starting the relay instance =="
# v4l2-relayd.service is a oneshot stub (ExecStart=/bin/true) that exists only
# so the template instances have something to be PartOf. The daemon itself runs
# as v4l2-relayd@<name>.service. On the Dell OEM image something started an
# instance; on stock Ubuntu nothing does - there is no udev rule and no .wants
# entry - so restarting the stub "succeeds" while no relay ever runs and
# /dev/video0 stays output-only. Start it, and make it survive a reboot.
INSTANCE=v4l2-relayd@default.service
WANTS=/etc/systemd/system/v4l2-relayd.service.wants

mkdir -p "$WANTS"
ln -sf /usr/lib/systemd/system/v4l2-relayd@.service "$WANTS/$INSTANCE"
systemctl daemon-reload
echo "  enabled at boot via $WANTS/$INSTANCE"

systemctl restart v4l2-relayd.service
systemctl restart "$INSTANCE"
sleep 4
printf '  %-34s %s\n' "$INSTANCE" "$(systemctl is-active "$INSTANCE")"

# The loopback advertises OUTPUT only until a producer attaches, so the
# capture bit is the real check that the relay is feeding it.
if v4l2-ctl -d /dev/video0 --info 2>/dev/null | grep -q 'Video Capture'; then
    echo "  /dev/video0 reports Video Capture - a producer is attached"
else
    echo "  WARNING: /dev/video0 has no Video Capture capability." >&2
    echo "  The loopback exists but nothing is feeding it; check the journal." >&2
fi

echo
echo "== recent log =="
journalctl -u 'v4l2-relayd*' --since '30 seconds ago' --no-pager 2>/dev/null \
    | grep -viE 'aiqb file name' | tail -15 | sed 's/^/  /'

echo
echo "Now verify frames actually reach /dev/video0:"
echo "  gst-launch-1.0 -q v4l2src device=/dev/video0 ! videoconvert ! fakesink num-buffers=10"
echo "Then retry the browser."
