#!/bin/bash
# Decide whether red and blue are swapped.
#
# The earlier Bayer check compared the two green CFA positions, which is blind
# to GRBG vs GBRG - both put greens on the same diagonal. A swap is invisible to
# grey-world white balance too, since balancing to neutral works either way. It
# only shows up in actual colours, and the CCM capture suggests it: blue read
# reddish, cyan read olive, both roughly complementary.
#
# Test: show a saturated primary fullscreen and see which channel the camera
# reports. No root needed - this reads the processed output, which is the point,
# since the demosaic assumes GRBG.
#
# Usage:  ./check-rb-swap.sh red|green|blue
set -u
C="${1:-}"
case "$C" in red|green|blue) ;; *) echo "usage: $0 red|green|blue" >&2; exit 1 ;; esac
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo "Display data/rbtest/$C.png fullscreen and fill the camera frame with it."
timeout 60 gst-launch-1.0 -q v4l2src device=/dev/video0 \
    ! videoconvert ! videorate ! video/x-raw,framerate=2/1 \
    ! identity eos-after=6 ! pngenc ! multifilesink location="$T/f-%02d.png" \
    >/dev/null 2>&1
python3 - "$T" "$C" <<'PY'
import glob, sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image
fs = sorted(glob.glob(sys.argv[1] + "/f-*.png"))
if not fs:
    sys.exit("no frames - is the camera free?")
im = Image.open(fs[-1]).convert("RGB")
w, h = im.size
# centre quarter only, to avoid the bezel and any surround
px = [im.getpixel((x, y))
      for y in range(h//4, 3*h//4, 4) for x in range(w//4, 3*w//4, 6)]
n = len(px)
r, g, b = (sum(p[i] for p in px)/n for i in range(3))
print(f"  displayed {sys.argv[2]:<6} -> camera R {r:5.1f}  G {g:5.1f}  B {b:5.1f}")
dom = "R" if r >= g and r >= b else ("G" if g >= b else "B")
print(f"  dominant channel: {dom}")
PY
