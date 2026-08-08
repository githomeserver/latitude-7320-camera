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

CONF=/etc/v4l2-relayd.d/default.conf
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

echo "== freeing the camera (stopping v4l2-relayd) =="
systemctl stop v4l2-relayd.service
sleep 2

best_fps=0
best_src=""

for src in "${CANDIDATES[@]}"; do
    printf '\n-- %s\n' "$src"
    start=$(date +%s.%N)
    if timeout "$BUDGET" gst-launch-1.0 -q $src \
         ! "video/x-raw,format=YUY2,width=1280,height=720" \
         ! fakesink sync=false num-buffers="$FRAMES" >/dev/null 2>&1; then
        end=$(date +%s.%N)
        fps=$(python3 -c "d=$end-$start; print(f'{$FRAMES/d:.1f}' if d>0 else '0')")
        echo "   $fps fps"
        if python3 -c "import sys; sys.exit(0 if $fps > $best_fps else 1)"; then
            best_fps="$fps"; best_src="$src"
        fi
    else
        echo "   failed or timed out (under $(python3 -c "print(f'{$FRAMES/$BUDGET:.1f}')") fps)"
    fi
    sleep 2
done

echo
echo "== best: $best_fps fps =="
echo "   $best_src"

if [ "$MODE" = "measure" ] || [ -z "$best_src" ]; then
    echo
    echo "(not changing anything)"
else
    cp -a "$CONF" "$CONF.before-tune"
    # VIDEOSRC may contain '!' and ',' - write the file rather than sed it.
    python3 - "$CONF" "$best_src" <<'EOF'
import sys
conf, src = sys.argv[1], sys.argv[2]
out = []
for line in open(conf):
    out.append(f"VIDEOSRC={src}\n" if line.startswith("VIDEOSRC=") else line)
open(conf, "w").writelines(out)
EOF
    echo
    echo "== new config =="
    sed 's/^/  /' "$CONF"
fi

echo
echo "== restarting v4l2-relayd =="
systemctl start v4l2-relayd.service
sleep 5
echo "Verify:  gst-launch-1.0 -q v4l2src device=/dev/video0 num-buffers=60 ! fakesink sync=false"
