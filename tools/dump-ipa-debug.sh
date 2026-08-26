#!/bin/bash
# Read the values libcamera's soft IPA actually computes, instead of inferring
# them from the output image.
#
# Every inference so far has been derived by comparing the raw sensor ratios
# against the processed frame, which requires assuming the ISP's gamma curve
# matches sRGB. It may not, and red sits where the two differ most, so those
# derived "applied gains" cannot be trusted. libcamera logs the real black
# level and the real AWB gains at Debug level - just read them.
#
# Run as root:  sudo ./dump-ipa-debug.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/../data/ipa-debug.log"
RAW="$(mktemp)"
trap 'rm -f "$RAW"; systemctl start ov5678-ondemand.service 2>/dev/null || true' EXIT

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"

echo "== stopping the camera pipeline =="
systemctl stop ov5678-ondemand.service
sleep 2

echo "== streaming with IPA debug logging =="
LIBCAMERA_LOG_LEVELS="IPASoft:DEBUG,IPASoftBL:DEBUG,IPASoftAwb:DEBUG,IPASoftAgc:DEBUG,SoftwareIsp:DEBUG" \
timeout 25 gst-launch-1.0 -q libcamerasrc \
    ! video/x-raw,width=1280,height=720 ! videoconvert \
    ! fakesink sync=false > "$RAW" 2>&1

{
echo "=== libcamera soft IPA debug ==="
date -Is
echo "tuning file present: $([ -f /usr/share/libcamera/ipa/simple/ov5675.yaml ] && echo yes || echo no)"
echo

echo "== black level =="
grep -iE 'black' "$RAW" | sort -u | head -10 | sed 's/^/  /' || echo "  (nothing logged)"

echo
echo "== awb / gains =="
grep -iE 'awb|gain|colour|color temp' "$RAW" | grep -viE 'AnalogueGain|analogue' \
    | sort -u | head -20 | sed 's/^/  /' || echo "  (nothing logged)"

echo
echo "== agc / exposure (context) =="
grep -iE 'exposure|agc' "$RAW" | sort -u | head -6 | sed 's/^/  /' || echo "  (nothing)"

echo
echo "== which log categories actually appeared =="
grep -oE '\] [A-Za-z]+ [a-z_]+\.cpp' "$RAW" | awk '{print $2}' | sort | uniq -c \
    | sort -rn | head -12 | sed 's/^/  /'

echo
echo "== any errors/warnings =="
grep -iE 'ERROR|WARN' "$RAW" | grep -viE 'EGL_' | sort -u | head -8 | sed 's/^/  /'
} 2>&1 | tee "$LOG"

chown --reference="$HERE" "$LOG" 2>/dev/null || true
echo
echo "full raw log kept at: $LOG.raw"
cp "$RAW" "$LOG.raw"
chown --reference="$HERE" "$LOG.raw" 2>/dev/null || true
