#!/bin/bash
# Work out where the frame rate is being lost.
#
# Known so far: through /dev/video0 the camera runs at ~1.9 fps, but the ISP is
# only asked for 1280x720, the sensor is in its binned 1296x972 mode, and
# v4l2-relayd uses about a third of one core - so it is neither resolution nor
# debayer cost. Meanwhile the sensor's exposure and analogue_gain are both
# pegged at their maximum, which is what an auto-exposure loop does when it is
# out of light.
#
# Three measurements, in order:
#   A  libcamera alone, dim        - does it collapse without the relay at all?
#   B  libcamera alone, lit        - does light bring it back? (AGC hypothesis)
#   C  through /dev/video0         - what the relay adds on top
#
# If A collapses, the fix is exposure/frame-duration limits in a tuning file.
# If A is fast and C is slow, the fix is in the relay pipeline.
#
# Run as root:  sudo ./diagnose-fps.sh

set -u

FRAMES=120
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

# Keep a transcript. The interesting numbers scroll past in a terminal and the
# per-run cam logs live in a temp dir that is deleted on exit, so without this
# the whole run has to be repeated just to re-read the result.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The loopback is not always /dev/video0: v4l2loopback takes the first free node,
# so where the IPU6's 64 raw ISYS nodes get there first it lands on /dev/video64.
# Detect it, and let the environment override. See issue #2.
LOOPBACK="${LOOPBACK:-$("$HERE/find-loopback.sh" 2>/dev/null || echo /dev/video0)}"
LOG="$HERE/../data/fps-diagnosis.log"
mkdir -p "$(dirname "$LOG")"
if [ -z "${OV5678_TEEING:-}" ]; then
    export OV5678_TEEING=1
    echo "(transcript: $LOG)"
    "$0" "$@" 2>&1 | tee "$LOG"
    chown --reference="$HERE" "$LOG" 2>/dev/null || true
    exit "${PIPESTATUS[0]}"
fi

SUBDEV=""
for d in /dev/v4l-subdev*; do
    nm="$(cat "/sys/class/video4linux/$(basename "$d")/name" 2>/dev/null || true)"
    case "$nm" in ov5675*) SUBDEV="$d"; break ;; esac
done

sensor_state() {
    [ -n "$SUBDEV" ] || { echo "    (sensor subdev not found)"; return; }
    v4l2-ctl -d "$SUBDEV" --list-ctrls 2>/dev/null \
        | grep -E 'exposure|analogue_gain' \
        | sed -E 's/.*(exposure|analogue_gain).*(min=[0-9]+ max=[0-9]+).*(value=[0-9]+).*/    \1 \2 \3/'
}

# cam prints e.g.  "90.31 (29.95 fps) cam0-stream0 seq: 000001 ..."
run_cam() {
    local label="$1" out="$TMP/$2"
    echo "== $label =="
    timeout 180 cam -c 1 --capture="$FRAMES" > "$out" 2>&1
    local n
    n=$(grep -cE '\([0-9.]+ fps\)' "$out" || true)
    if [ "${n:-0}" -lt 5 ]; then
        echo "    captured only ${n:-0} frames - see below"
        grep -viE 'EGL_|INFO Camera|INFO IPA' "$out" | tail -5 | sed 's/^/    /'
        return
    fi
    python3 - "$out" <<'EOF'
import re, sys
v = [float(m) for m in re.findall(r'\(([0-9.]+) fps\)', open(sys.argv[1]).read())]
v = [x for x in v if x > 0]
if not v:
    print("    no fps samples"); raise SystemExit
first, last = v[:10], v[-10:]
print(f"    frames {len(v)}")
print(f"    first 10 avg {sum(first)/len(first):6.1f} fps")
print(f"    last  10 avg {sum(last)/len(last):6.1f} fps")
print(f"    min {min(v):.1f}  max {max(v):.1f}")
EOF
    echo "  sensor after:"
    sensor_state
}

echo "== stopping the camera pipeline to free it =="
systemctl stop ov5678-ondemand.service
sleep 2
echo "  sensor before:"
sensor_state
echo

run_cam "A - libcamera alone, scene as-is" a.log
echo

if [ -t 0 ]; then
    echo "== B needs a bright scene =="
    echo "   Point a phone torch at the camera, or face a bright window."
    printf "   Press Enter when the scene is bright: "
    read -r _
else
    echo "== B skipped (no terminal to prompt on) =="
fi
run_cam "B - libcamera alone, bright" b.log
echo

echo "== restarting the camera pipeline =="
systemctl start ov5678-ondemand.service
sleep 6

echo "== C - through /dev/video0 (the relay path) =="
S=$(date +%s.%N)
if timeout 120 gst-launch-1.0 -q v4l2src device="$LOOPBACK" num-buffers=60 \
     ! fakesink sync=false >/dev/null 2>&1; then
    E=$(date +%s.%N)
    python3 -c "d=$E-$S; print(f'    60 frames in {d:.1f}s -> {60/d:.1f} fps')"
else
    echo "    timed out (under 0.5 fps)"
fi
echo "  sensor after:"
sensor_state

echo
echo "== reading =="
echo "  A slow and B fast  -> auto-exposure; fix is Agc/FrameDurationLimits tuning"
echo "  A slow and B slow  -> not light; look at the sensor mode or libcamera"
echo "  A fast and C slow  -> the relay pipeline is the bottleneck"
