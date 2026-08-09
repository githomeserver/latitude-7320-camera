#!/bin/bash
# Measure throughput at the binned and full-resolution sensor modes.
#
# RGB-IR requires the unbinned 2592x1944 mode - binning averages IR pixels in
# with colour pixels and destroys the mosaic. That is 4x the pixels of what we
# run today, so the question is whether the GPU debayer keeps up. This answers
# it before anyone writes a pipeline-handler patch.
#
# Frame rate is measured from the SLOPE of two runs with different buffer
# counts, so pipeline startup - which is seconds, and would otherwise dominate
# a short run - cancels out.
#
# Run as root:  sudo ./bench-fullres.sh
set -u
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

export LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu
export LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera/ipa
export GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/../data/fullres-bench.log"
mkdir -p "$(dirname "$LOG")"
# Tee everything: the other tools in here log to data/ and this one did not,
# which made a completed run unreviewable.
exec > >(tee "$LOG") 2>&1
cleanup() { echo; echo "== restarting v4l2-relayd =="; systemctl start v4l2-relayd.service 2>/dev/null || true; chown "${SUDO_USER:-root}" "$LOG" 2>/dev/null || true; }
trap cleanup EXIT
echo "== stopping v4l2-relayd =="
systemctl stop v4l2-relayd.service
sleep 2

run() {   # $1=w $2=h $3=nbuffers  -> seconds
    local t0 t1
    t0=$(date +%s.%N)
    timeout 180 gst-launch-1.0 -q libcamerasrc \
        ! "video/x-raw,width=$1,height=$2" \
        ! identity eos-after="$3" ! fakesink sync=false >/dev/null 2>&1
    t1=$(date +%s.%N)
    echo "$t1 - $t0" | bc
}

bench() {  # $1=w $2=h $3=label
    local a b fps
    printf '  %-22s ' "$3"
    a=$(run "$1" "$2" 40)
    b=$(run "$1" "$2" 160)
    fps=$(echo "scale=2; 120 / ($b - $a)" | bc 2>/dev/null)
    # A negative or absurd value means one run failed or the timeout hit.
    if [ -z "$fps" ] || [ "$(echo "$fps <= 0 || $fps > 200" | bc)" = "1" ]; then
        echo "FAILED (40buf ${a}s, 160buf ${b}s)"
    else
        printf 'stable %6.2f fps   (40buf %.1fs, 160buf %.1fs)\n' "$fps" "$a" "$b"
    fi
}

for mode in gpu cpu; do
    echo
    if [ "$mode" = cpu ]; then
        export LIBCAMERA_SOFTISP_MODE=cpu
        echo "== CPU debayer =="
    else
        unset LIBCAMERA_SOFTISP_MODE
        echo "== GPU debayer (current default) =="
    fi
    bench 1280 720   "1280x720 (binned, now)"
    bench 2592 1944  "2592x1944 (RGB-IR needs this)"
done

echo
echo "The full-res figure is the budget an RGB-IR pre-pass has to fit inside."
