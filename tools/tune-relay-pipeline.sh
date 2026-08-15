#!/bin/bash
# Find a v4l2-relayd source pipeline that actually runs at a usable frame rate.
#
# THE PROBLEM
#
# libcamerasrc left to itself configures the sensor's full-resolution mode -
# 2560x1600 ABGR8888, about 16 MB per frame - and the software ISP debayers all
# of it on the CPU before videoscale shrinks it to the 1280x720 the relay
# wants. Measured result: under 2 fps.
#
# ov5675 has a binned 1296x972 mode with a quarter of the pixels. Constraining
# libcamerasrc up front should make libcamera pick it, so the software ISP has
# far less to do. This measures the candidates rather than assuming.
#
# Run as root:  sudo ./tune-relay-pipeline.sh          measure, then apply best
#               sudo ./tune-relay-pipeline.sh measure  measure only, change nothing

set -u

# See the note in fix-browser-camera.sh: the per-instance file exists only on
# the OEM image; a stock Ubuntu install keeps the config in /etc/default.
CONF=""
for c in /etc/v4l2-relayd.d/default.conf /etc/default/v4l2-relayd; do
    [ -f "$c" ] && CONF="$c"
done
[ -n "$CONF" ] || { echo "ERROR: no v4l2-relayd config found" >&2; exit 1; }
FRAMES=60
BUDGET=40

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

MODE="${1:-apply}"

CANDIDATES=(
  "libcamerasrc ! video/x-raw,width=1296,height=972 ! videoconvert ! videoscale"
  "libcamerasrc ! video/x-raw,width=[320,1600],height=[240,1200] ! videoconvert ! videoscale"
  "libcamerasrc ! video/x-raw,width=1280,height=720 ! videoconvert"
  "libcamerasrc ! videoconvert ! videoscale"
)

# MEASURE THROUGH THE REAL RELAY, not a standalone pipeline.
#
# An earlier version ran each candidate as
#   gst-launch-1.0 $src ! video/x-raw,format=YUY2,width=1280,height=720 ! fakesink
# which looks equivalent and is not. That trailing capsfilter constrains
# negotiation UPSTREAM, so libcamerasrc is forced to 1280x720 whatever the
# candidate asked for. In the real relay the input pipeline instead terminates
# at v4l2-relayd's internal appsink, which does not push the output caps
# upstream - so a candidate with a caps RANGE is free to pick the largest size
# in it. That is exactly what happened: the range candidate measured 23.8 fps
# in the old harness and ran at 8 fps in production, because libcamera chose
# 1600x1200 (not a sensor mode, so full-res 2592x1944 scaled down) instead of
# 1280x720 (the binned mode).
#
# So each candidate is now written to the config, the relay restarted, and the
# frame rate taken from /dev/video0 - the same device a browser opens. Slower
# to run, but it measures the thing being configured.

# The relay daemon runs as a template instance; the plain unit is a oneshot
# stub. Find the live instance, or fall back to @default.
INSTANCE="$(systemctl list-units --all --no-legend 'v4l2-relayd@*' 2>/dev/null \
            | awk '{print $1}' | head -1)"
[ -n "$INSTANCE" ] || INSTANCE="v4l2-relayd@default.service"
echo "== relay instance: $INSTANCE =="

cp -a "$CONF" "$CONF.before-tune"

set_videosrc() {                     # $1 = pipeline
    python3 - "$CONF" "$1" <<'EOF'
import sys
conf, src = sys.argv[1], sys.argv[2]
out = []
seen = False
for line in open(conf):
    if line.startswith("VIDEOSRC="):
        out.append(f"VIDEOSRC={src}\n"); seen = True
    else:
        out.append(line)
if not seen:
    out.append(f"VIDEOSRC={src}\n")
open(conf, "w").writelines(out)
EOF
}

measure_via_loopback() {             # echoes fps, or 0
    local start end
    systemctl restart "$INSTANCE" >/dev/null 2>&1
    sleep 4
    start=$(date +%s.%N)
    if timeout "$BUDGET" gst-launch-1.0 -q v4l2src device=/dev/video0 \
         num-buffers="$FRAMES" ! fakesink sync=false >/dev/null 2>&1; then
        end=$(date +%s.%N)
        python3 -c "d=$end-$start; print(f'{$FRAMES/d:.1f}' if d>0 else '0')"
    else
        echo 0
    fi
}

best_fps=0
best_src=""

for src in "${CANDIDATES[@]}"; do
    printf '\n-- %s\n' "$src"
    set_videosrc "$src"
    fps="$(measure_via_loopback)"
    if [ "$fps" = "0" ]; then
        echo "   failed or timed out (under $(python3 -c "print(f'{$FRAMES/$BUDGET:.1f}')") fps)"
    else
        # Report what libcamera actually negotiated. A candidate can hit a good
        # frame rate for the wrong reason, and the negotiated size says which.
        neg="$(journalctl -u "$INSTANCE" --since '30 seconds ago' --no-pager 2>/dev/null \
               | grep -oE 'configuring streams: \(0\) [0-9]+x[0-9]+' | tail -1 \
               | grep -oE '[0-9]+x[0-9]+')"
        echo "   $fps fps    negotiated ${neg:-unknown}"
        if python3 -c "import sys; sys.exit(0 if $fps > $best_fps else 1)"; then
            best_fps="$fps"; best_src="$src"
        fi
    fi
    sleep 2
done

echo
echo "== best: $best_fps fps =="
echo "   $best_src"

# Measuring rewrote the config for every candidate, so the file currently holds
# whichever one was tested last. Always put back either the winner or the
# original - never leave the last candidate in place by accident.
if [ "$MODE" = "measure" ] || [ -z "$best_src" ]; then
    cp -f "$CONF.before-tune" "$CONF"
    echo
    echo "(measure only - config restored from $CONF.before-tune)"
else
    set_videosrc "$best_src"
    echo
    echo "== new config =="
    sed 's/^/  /' "$CONF"
fi

echo
echo "== restarting $INSTANCE =="
systemctl restart "$INSTANCE"
sleep 5
systemctl is-active "$INSTANCE" | sed 's/^/  /'
echo "Verify:  gst-launch-1.0 -q v4l2src device=/dev/video0 num-buffers=60 ! fakesink sync=false"
