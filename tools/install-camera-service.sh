#!/bin/bash
# Feed the v4l2loopback device directly with GStreamer, replacing v4l2-relayd.
#
# WHY. v4l2-relayd is the bottleneck, by a factor of twenty. Measured on this
# machine, all with the RGB-IR pre-pass active and the same full-resolution
# capture:
#
#   libcamerasrc -> scale -> convert -> v4l2sink -> loopback -> reader   29.9 fps
#   videotestsrc                      -> v4l2sink -> loopback -> reader  29.2 fps
#   the identical work through v4l2-relayd                                1.3 fps
#
# The input pipeline alone benchmarks at 22-24 fps to a fakesink, so neither
# libcamera, the pre-pass, the scaler nor the loopback is responsible. What
# v4l2-relayd adds is an appsink/appsrc bridge between two pipelines, and that
# is where the frames go. Cutting it out restores full frame rate with no
# change to libcamera at all.
#
# This matters beyond frame rate: chasing the throughput problem inside the
# debayer would have been wasted effort, and the CPU pre-pass was written off
# as "a dead end on this hardware" on the strength of numbers that were
# actually measuring the relay.
#
# WHAT IS LOST. v4l2-relayd shows a splash image when no producer is running
# and starts on demand. This service simply holds the camera open. If you want
# the camera released when unused, keep the relay and accept the frame rate.
#
# Run as root:  sudo ./install-camera-service.sh          install and start
#               sudo ./install-camera-service.sh revert   back to v4l2-relayd

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT=/etc/systemd/system/ov5678-camera.service
LOOPBACK=/dev/video0
# Respect the environment. This was a plain assignment, so `IRSUB=2.0 ./install`
# silently ran at 1.0 - an entire IR-subtraction sweep produced byte-identical
# results and looked like the feature doing nothing.
IRSUB="${IRSUB:-1.0}"

# Let the IR coefficient follow how much of the IR channel is real signal.
#
# IR is the weakest channel on this sensor and so the first to run out of
# photons. In a dark room its cells carry a few counts of signal under a
# comparable amount of noise, and subtracting 2x of that from R, G and B is
# subtracting noise rather than infrared - the largest single source of grain
# measured on this hardware in low light.
#
# Each cell's coefficient is shrunk by k = IRSUB * SNR^2 / (1 + SNR^2), the
# least-squares answer, so it is full strength where IR is clean and falls away
# where IR is noise. Per cell, not per frame: a frame holding both a lamp and a
# dim wall has a mean IR dominated by the lamp. Measured on a starved frame,
# 1.13x less grain with the R/G and B/G ratios unmoved (0.9162 -> 0.9176).
#
# Set to 0 for the old fixed-coefficient behaviour.
IRSUB_ADAPT="${IRSUB_ADAPT:-1}"

# Green resolution vs noise, 0.0 to 1.0. 0.0 is the long-standing behaviour and
# is bit-for-bit identical to it (verified over a full frame). 1.0 gives each
# output green its own 2x2 quadrant of the 4x4 cell instead of one cell average
# written twice: measured 1.49x the vertical detail, but 1.43x the noise,
# because two samples average less noise than eight. Detail-to-noise is flat
# across the range, so this is a taste knob, not a quality setting. Try 0.5.
SHARPNESS="${SHARPNESS:-0.0}"

# Temporal denoise. DENOISE is the blend weight given to the current frame in
# still areas: lower denoises harder, 1.0 disables. This sensor is noise
# limited, so this is the single biggest image-quality lever available -
# measured 2.0x less temporal noise at 0.25, up to 3.8x at 0.10. Lower values
# also ghost more: at 0.15 a moving object leaves a visible double image. 0.35
# is the default because it keeps most of the noise reduction with markedly
# less trailing - raise it further if you see smearing when you move. Motion is detected per
# block with the frame's own noise floor subtracted, so still areas are
# averaged hard while moving ones pass through.
DENOISE="${DENOISE:-0.35}"
DENOISE_THR="${DENOISE_THR:-40}"

# Chroma blur radius in cells: 0 off, 1 a 3x3 average, 2 a 5x5. Red and blue are
# already one value per 4x4 sensor block, so smoothing them costs almost nothing
# visible while halving the noise that dominates the picture. Green is untouched.
CHROMA_BLUR="${CHROMA_BLUR:-1}"

# Lens shading. Path to a per-channel gain map, or empty to disable. The map
# must be measured from RAW mosaic frames over the FULL 4:3 sensor field, which
# is what the pre-pass sees - see tools/measure-lens-shading.sh --raw. A map
# derived from the processed 16:9 output is wrong twice over: the CCM mixes the
# channels, and the crop puts its corners at a smaller radius than the sensor's.
# NOTE the quotes on the Environment= line below. systemd splits unquoted
# values on whitespace, and this project lives under "Claude Code". Unquoted,
# the service silently received RGBIR_SHADING=/home/sahan/Claude and loaded no
# shading at all, with no error anywhere.
# Run the pipeline only while something has the loopback open. The producer
# costs a full CPU core continuously - on this fanless machine that is an
# audible fan and a hot lid for nothing when no app is using the camera.
# ONDEMAND=0 reverts to the always-on behaviour.
ONDEMAND="${ONDEMAND:-1}"
_default_shading="$(cd "$HERE/.." && pwd)/data/lens-shading-measured-raw.bin"
# A fresh clone has no measured map - that comes from measure-lens-shading.sh
# --raw, which needs the user to hold white paper over the lens. Default to none
# rather than to a path that does not exist, so a first install is quiet.
[ -e "$_default_shading" ] || _default_shading=""
SHADING="${SHADING-$_default_shading}"

# Exposure-value offset, in stops, applied while auto-exposure stays enabled.
# Dimming the subject does NOT reduce exposure - the AGC simply exposes longer
# to reach the same mean level, which is why screen brightness had almost no
# effect on clipping.
#
# EV DOES NOT CURRENTLY WORK, and the note that used to sit here saying it was
# "the knob that actually works" was wrong. libcamerasrc accepts the property,
# but this build never advertises ExposureValue, so it is dropped before it
# reaches the IPA - cam --list-controls returns exactly three controls here:
# Saturation, Contrast, Gamma. Nothing for exposure, gain or white balance. The
# AGC is fine, the picture is correctly exposed; there is simply no knob. Setting
# the sensor's own exposure control with v4l2-ctl is overwritten within a frame.
# Left in place in case a later libcamera registers it.
EV="${EV:-0}"

# Chroma gain applied after the colour matrix, 0.0 to 2.0. 1.0 leaves it alone.
#
# This is the cheap way to buy apparent colour on this sensor. The matrix that
# would fully correct its separation needs off-diagonals of +-3 and amplifies
# noise 5.3x, against 1.9x for the one that ships, which is why the shipped
# matrix is deliberately a compromise. A saturation multiplier costs chroma
# noise instead of matrix conditioning - and chroma noise is what CHROMA_BLUR
# already halves, so it is far more affordable here than the arithmetic alone
# suggests.
#
# Only works because the tuning file lists Ccm BEFORE Adjust. Registration of
# controls::Saturation happens in Adjust::init and reads a flag only Ccm::init
# sets, so with the entries the other way round the camera never advertises the
# control and the value is dropped before it reaches the IPA - silently, and
# with a matrix installed. See tools/install-ccm.sh. Verify with:
#
#   cam --list-controls | grep -i saturation
SATURATION="${SATURATION:-1.0}"

# Omitted from the command line entirely at 1.0, so the default install produces
# the same unit file it always did and the property only appears when asked for.
case "$SATURATION" in
    ''|*[!0-9.]*) echo "ERROR: SATURATION must be a number, got '$SATURATION'" >&2; exit 1 ;;
esac
if [ "$SATURATION" = "1.0" ] || [ "$SATURATION" = "1" ]; then
    SAT_PROP=""
else
    SAT_PROP=" saturation=$SATURATION"
fi

# Output geometry. The sensor is 4:3 (2584x1944 after the debayer's crop), so a
# 16:9 output must CROP, never stretch: forcing 4:3 into 16:9 with videoscale is
# what made everything 34% wide and unusable for judging colour.
#
#   ASPECT=16:9  ->  crop 2584x1454 out of the middle, then scale to 1280x720
#   ASPECT=4:3   ->  no crop, full field of view, scale to 1280x960
#
# 16:9 costs vertical field of view; 4:3 keeps all of it. Most conferencing
# apps expect 16:9.
# With the half-size pre-pass the debayer emits 1296x972, so ask libcamerasrc
# for the final size directly: libcamera crops its window and gstreamer does no
# scaling at all. Requesting 2584-wide frames and scaling them down afterwards
# was moving 20 MB per frame through videoscale for nothing.
ASPECT="${ASPECT:-16:9}"
if [ "$ASPECT" = "4:3" ]; then
    WIDTH=1280; HEIGHT=960; CROP=""; SRCH=1944
else
    WIDTH=1280; HEIGHT=720
    # Crop in LIBCAMERA, not gstreamer: asking libcamerasrc for a 16:9 frame
    # makes the debayer's own window smaller, so it processes fewer pixels.
    # A videocrop after the fact costs extra work on 20 MB frames and measured
    # slower (9.5 fps) than doing no crop at all.
    SRCH=1454
    CROP=""
fi

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

if [ "${1:-install}" = "revert" ]; then
    systemctl disable --now ov5678-ondemand.service 2>/dev/null || true
    rm -f /etc/systemd/system/ov5678-ondemand.service
    systemctl disable --now ov5678-camera.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
    systemctl start v4l2-relayd.service 2>/dev/null || true
    systemctl start v4l2-relayd@default.service 2>/dev/null || true
    echo "reverted to v4l2-relayd"
    exit 0
fi

echo "== stopping v4l2-relayd =="
systemctl disable --now v4l2-relayd@default.service 2>/dev/null || true
systemctl stop v4l2-relayd.service 2>/dev/null || true

LIBEXEC=/usr/local/libexec
SHAREDIR=/usr/local/share/ov5678
install -d "$LIBEXEC" "$SHAREDIR"
install -m755 "$HERE/ov5678-ondemand.sh" "$LIBEXEC/ov5678-ondemand.sh"
if [ -n "$SHADING" ] && [ -e "$SHADING" ]; then
    install -m644 "$SHADING" "$SHAREDIR/lens-shading.bin"
    SHADING="$SHAREDIR/lens-shading.bin"
fi

cat > "$UNIT" <<EOF
[Unit]
Description=OV5678 camera into v4l2loopback (replaces v4l2-relayd)
After=multi-user.target

[Service]
Type=simple
# The locally built libcamera carries the RGB-IR pre-pass and the AWB fix.
Environment=LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu
Environment=LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera/ipa
Environment=GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0
# RGB-IR needs the unbinned sensor mode: binning averages infrared pixels in
# with colour ones and destroys the 4x4 mosaic before it can be read.
Environment=LIBCAMERA_RGBIR=1
Environment=RGBIR_IRSUB=$IRSUB
Environment=RGBIR_IRSUB_ADAPT=$IRSUB_ADAPT
Environment=RGBIR_SHARPNESS=$SHARPNESS
Environment=RGBIR_DENOISE=$DENOISE
Environment=RGBIR_DENOISE_THR=$DENOISE_THR
Environment=RGBIR_CHROMA_BLUR=$CHROMA_BLUR
Environment="RGBIR_SHADING=$SHADING"
Environment=LIBCAMERA_SOFTISP_MODE=cpu
ExecStart=/usr/bin/gst-launch-1.0 -q libcamerasrc exposure-value=$EV$SAT_PROP ! video/x-raw,width=$WIDTH,height=$HEIGHT ! videoconvert ! video/x-raw,format=YUY2 ! v4l2sink device=$LOOPBACK
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Placeholder producer: holds a format on the loopback while the real pipeline
# is stopped, so an application can still negotiate and be noticed. Black at
# 1 fps, which costs well under 1% of a core.
cat > /etc/systemd/system/ov5678-placeholder.service <<EOF
[Unit]
Description=OV5678 loopback placeholder (keeps a format on $LOOPBACK when idle)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/gst-launch-1.0 -q videotestsrc pattern=black ! video/x-raw,width=$WIDTH,height=$HEIGHT,framerate=1/1 ! videoconvert ! video/x-raw,format=YUY2 ! v4l2sink device=$LOOPBACK
Restart=always
RestartSec=2
Nice=10
EOF

cat > /etc/systemd/system/ov5678-ondemand.service <<EOF
[Unit]
Description=Start the OV5678 pipeline only while the loopback is in use
After=multi-user.target

[Service]
Type=simple
ExecStart=$LIBEXEC/ov5678-ondemand.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
if [ "$ONDEMAND" = 1 ]; then
    # The producer must NOT be enabled at boot, or it runs regardless of
    # whether anything is watching, which is the whole problem.
    systemctl disable ov5678-camera.service >/dev/null 2>&1
    systemctl disable ov5678-placeholder.service >/dev/null 2>&1
    systemctl enable ov5678-ondemand.service >/dev/null 2>&1
    systemctl restart ov5678-camera.service      # so settings apply immediately
    systemctl restart ov5678-ondemand.service
else
    systemctl disable --now ov5678-ondemand.service >/dev/null 2>&1
    systemctl enable ov5678-camera.service >/dev/null 2>&1
    # restart, not "enable --now": --now only STARTS an inactive unit, so
    # re-running this script to change settings against an already-running
    # service silently changed nothing at all.
    systemctl restart ov5678-camera.service
fi
sleep 6
printf '  service: %s\n' "$(systemctl is-active ov5678-camera.service)"
if [ -n "$SHADING" ]; then
    # Ask libcamera, not systemd. The path contains a space, so any check that
    # word-splits systemd's Environment output reports a false failure - which
    # the first version of this check did. The library logging that it opened
    # the file is the only thing that actually proves it arrived intact.
    if [ "$ONDEMAND" = 1 ]; then
        # In on-demand mode the real pipeline is not running at install time, so
        # there is no libcamera log to check yet. Verify the file instead, and
        # let the watcher's first real start do the rest.
        if [ -e "$SHADING" ]; then
            echo "  lens shading: $SHADING (loads when the pipeline starts)"
        else
            echo "  WARNING: shading map does not exist: $SHADING" >&2
        fi
    elif [ ! -e "$SHADING" ]; then
        echo "  WARNING: shading map does not exist: $SHADING" >&2
    else
        ok=""
        for _ in 1 2 3 4 5 6 7 8; do
            if journalctl -u ov5678-camera.service --since "-2 min" --no-pager 2>/dev/null \
               | grep -q 'lens shading .* loaded'; then ok=1; break; fi
            sleep 2
        done
        if [ -n "$ok" ]; then
            echo "  lens shading: loaded from $SHADING"
        else
            echo "  WARNING: libcamera never reported loading $SHADING" >&2
        fi
    fi
fi
v4l2-ctl -d "$LOOPBACK" --info 2>/dev/null | grep -q 'Video Capture' \
    && echo "  $LOOPBACK reports Video Capture" \
    || echo "  WARNING: $LOOPBACK is not capture-capable" >&2
echo
echo "Verify:  gst-launch-1.0 -q v4l2src device=$LOOPBACK num-buffers=200 ! fakesink sync=false"
echo "Measure over 200+ frames - shorter runs read high because buffers absorb them."
