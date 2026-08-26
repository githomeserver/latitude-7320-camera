#!/bin/bash
# Collect the evidence for a libcamera soft-ISP AWB bug report.
#
# Measures, on ONE scene in ONE run:
#   A  the sensor's native channel balance, from raw Bayer (relay stopped)
#   B  the balance after libcamera's soft ISP (via the relay's /dev/video0)
#   C  whether AwbEnable=false + ColourGains changes anything
#
# A grey-world AWB targeting unity ratios should bring B to R/G = B/G = 1.000
# regardless of what the camera is pointed at. Reporting A alongside B shows
# how far short it falls and in which direction.
#
# Point the camera at a NEUTRAL, evenly lit surface filling the frame and do
# not move it or change the lighting during the run.
#
# Run as root:  sudo ./awb-evidence.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/../data/awb-evidence.log"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; systemctl start ov5678-ondemand.service 2>/dev/null || true' EXIT

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"

# Ratios of a processed frame, in LINEAR light (undo the sRGB transfer first -
# comparing gamma-encoded ratios against linear raw ratios is meaningless).
linear_ratios() {
    python3 - "$1" <<'PY'
import glob, sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image
fs = sorted(glob.glob(sys.argv[1] + "/*.png"))
if not fs:
    print("no frames"); raise SystemExit
lut = [(c/255.0/12.92 if c/255.0 <= 0.04045 else ((c/255.0+0.055)/1.055)**2.4)
       for c in range(256)]
im = Image.open(fs[-1]).convert("RGB")
px = list(im.getdata())[::97]
n = len(px)
r = sum(lut[p[0]] for p in px)/n
g = sum(lut[p[1]] for p in px)/n
b = sum(lut[p[2]] for p in px)/n
print(f"R/G {r/g:.4f}  B/G {b/g:.4f}" if g > 0.002 else "frame too dark")
PY
}

grab() {   # $1 = extra libcamerasrc props, $2 = outdir
    mkdir -p "$2"; rm -f "$2"/*.png
    # shellcheck disable=SC2086
    timeout 45 gst-launch-1.0 -q libcamerasrc $1 \
        ! video/x-raw,width=1280,height=720 ! videoconvert \
        ! videorate ! video/x-raw,framerate=2/1 \
        ! identity eos-after=8 ! pngenc \
        ! multifilesink location="$2/f-%02d.png" >/dev/null 2>&1
}

{
echo "=== libcamera soft-ISP AWB evidence ==="
date -Is
echo "libcamera: $(dpkg -l libcamera0.7 2>/dev/null | tail -1 | awk "{print \$3}")"
echo "sensor:    ov5675 (ACPI OVTI5678), Dell Latitude 7320 Detachable, IPU6"
echo "kernel:    $(uname -r)"
echo

echo "== A. sensor native, raw Bayer =="
systemctl stop ov5678-ondemand.service
sleep 2
python3 "$HERE/check-bayer-order.py" 2>&1 | grep -E 'CFA|black level|signal |^  +[0-9]|\(0,|\(1,|native balance|diagonal'
echo

echo "== C. does AwbEnable=false + ColourGains do anything? =="
for gains in "2.0,1.0" "4.0,1.0" "8.0,1.0"; do
    grab "awb-enable=false colour-gains=<$gains>" "$TMP/c"
    printf '  colour-gains=<%-9s ->  %s\n' "$gains>" "$(linear_ratios "$TMP/c")"
done
echo "  (red gain varied 4x; if the ratios do not move, the control is ignored)"
echo

echo "== B. after the soft ISP, AWB enabled (default) =="
grab "" "$TMP/b"
echo "  $(linear_ratios "$TMP/b")"
echo "  (a grey-world AWB targeting unity should reach R/G = B/G = 1.000)"
echo

echo "== restarting relay =="
systemctl start ov5678-ondemand.service
sleep 5
} 2>&1 | tee "$LOG"

chown --reference="$HERE" "$LOG" 2>/dev/null || true
echo
echo "transcript: $LOG"
