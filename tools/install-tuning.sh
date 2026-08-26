#!/bin/bash
# Install the ov5675 libcamera tuning file and measure whether it fixes the
# green cast.
#
# The tuning file pins the sensor's black level. Without it, BlackLevel guesses
# the pedestal from the scene histogram, Awb::calculateRgbMeans() subtracts that
# guess before computing grey-world gains, and on this sensor the pedestal is
# about twice the red signal - so the error lands on the red gain.
#
# Predicted from the measured raw values: R/G and B/G should go from
# 0.391 / 0.938 to approximately 1.000 / 1.000.
#
# Run as root:  sudo ./install-tuning.sh          install, then measure
#               sudo ./install-tuning.sh revert   remove it

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../libcamera/ov5675.yaml"
# The locally built libcamera searches its own prefix, so install to every
# IPA config dir that exists rather than assuming the distro one.
DESTS=()
for d in /usr/share/libcamera/ipa/simple /usr/local/share/libcamera/ipa/simple; do
    [ -d "$d" ] && DESTS+=("$d/ov5675.yaml")
done
LOG="$HERE/../data/tuning-result.log"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"

if [ "${1:-install}" = "revert" ]; then
    for d in "${DESTS[@]}"; do rm -f "$d"; echo "removed $d"; done
    systemctl restart ov5678-ondemand.service
    sleep 5
    echo "back to the guessed black level"
    exit 0
fi

[ -f "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }

# Ratios in LINEAR light from the relay's /dev/video0.
ratios() {
    rm -f "$TMP"/f-*.png
    timeout 40 gst-launch-1.0 -q v4l2src device=/dev/video0 \
        ! videoconvert ! videorate ! video/x-raw,framerate=2/1 \
        ! identity eos-after=8 ! pngenc \
        ! multifilesink location="$TMP/f-%02d.png" >/dev/null 2>&1
    python3 - "$TMP" <<'PY'
import glob, sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image
fs = sorted(glob.glob(sys.argv[1] + "/f-*.png"))
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

{
echo "=== ov5675 tuning file result ==="
date -Is
echo
echo "== before (no tuning file, black level guessed) =="
echo "  $(ratios)"

echo
echo "== installing =="
for d in "${DESTS[@]}"; do
    install -m 0644 "$SRC" "$d"
    echo "  -> $d"
done
grep -E 'blackLevel:' "${DESTS[0]}" | sed 's/^/     /'
MARK="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart ov5678-ondemand.service
sleep 6

echo
echo "== after (black level pinned to 4122 >> 8 = 16) =="
echo "  $(ratios)"

echo
echo "  target is R/G = B/G = 1.000"
echo "  predicted from the raw measurements: 1.005 / 0.999"

echo
echo "== is libcamera actually loading it? =="
# Only look after the restart. A wider window catches the "not found" warning
# from the before-measurement and reports a false negative.
if journalctl -u 'v4l2-relayd*' --since "$MARK" --no-pager 2>/dev/null \
     | grep -q 'Using tuning file.*ov5675.yaml'; then
    echo "  yes - libcamera reports: Using tuning file .../ov5675.yaml"
else
    echo "  NO - no 'Using tuning file' line since the restart"
    journalctl -u 'v4l2-relayd*' --since "$MARK" --no-pager 2>/dev/null \
        | grep -iE 'ov5675.yaml|uncalibrated' | tail -3 | sed 's/^/    /'
fi
} 2>&1 | tee "$LOG"

chown --reference="$HERE" "$LOG" 2>/dev/null || true
echo
echo "transcript: $LOG"
echo "Revert with: sudo $0 revert"
