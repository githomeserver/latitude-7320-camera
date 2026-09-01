#!/bin/bash
# Measure the current colour balance of /dev/video0. No root needed.
# Point the camera at a neutral, well-lit surface first.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The loopback is not always /dev/video0: v4l2loopback takes the first free node,
# so where the IPU6's 64 raw ISYS nodes get there first it lands on /dev/video64.
# Detect it, and let the environment override. See issue #2.
LOOPBACK="${LOOPBACK:-$("$HERE/find-loopback.sh" 2>/dev/null || echo /dev/video0)}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
timeout 40 gst-launch-1.0 -q v4l2src device="$LOOPBACK" \
    ! videoconvert ! videorate ! video/x-raw,framerate=2/1 \
    ! identity eos-after=8 ! pngenc \
    ! multifilesink location="$T/f-%02d.png" >/dev/null 2>&1
python3 - "$T" <<'PY'
import glob, sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image
fs = sorted(glob.glob(sys.argv[1] + "/f-*.png"))
if not fs:
    print("no frames captured"); raise SystemExit(1)
lut = [(c/255.0/12.92 if c/255.0 <= 0.04045 else ((c/255.0+0.055)/1.055)**2.4)
       for c in range(256)]
im = Image.open(fs[-1]).convert("RGB")
px = list(im.getdata())[::97]; n = len(px)
r = sum(lut[p[0]] for p in px)/n
g = sum(lut[p[1]] for p in px)/n
b = sum(lut[p[2]] for p in px)/n
sr, sg, sb = (sum(p[i] for p in px)/n for i in range(3))
print(f"  linear   R/G {r/g:.3f}   B/G {b/g:.3f}     (1.000 = neutral)")
print(f"  8-bit    R {sr:.0f}  G {sg:.0f}  B {sb:.0f}")
mx, mn = max(sr,sg,sb), min(sr,sg,sb)
print(f"  approx saturation {100*(mx-mn)/mx:.1f}%   (webcamtests-style)")
PY
