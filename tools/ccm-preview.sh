#!/bin/bash
# Capture one frame and render it through candidate colour correction matrices,
# for eyeball tuning. No root needed, nothing on the system is changed.
#
# Hold a subject with colours you know in front of the camera - a record sleeve,
# a book cover, something with saturated reds and blues - and run this. Compare
# the variants, then install the winner with tools/install-ccm.sh.
#
# Usage:  ./ccm-preview.sh                        default candidate set
#         ./ccm-preview.sh sat=2.0 sat=2.4        specific candidates
#
# Output: /tmp/ccm-preview.png  (and the untouched capture beside it)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The loopback is not always /dev/video0: v4l2loopback takes the first free node,
# so where the IPU6's 64 raw ISYS nodes get there first it lands on /dev/video64.
# Detect it, and let the environment override. See issue #2.
LOOPBACK="${LOOPBACK:-$("$HERE/find-loopback.sh" 2>/dev/null || echo /dev/video0)}"
OUT=/tmp/ccm-preview.png
CAP=/tmp/ccm-capture.png
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Refuse to run if a CCM is already installed: try-ccm.py assumes the capture
# came through an identity matrix, and tuning on top of an installed one
# compounds the two silently.
for y in /usr/local/share/libcamera/ipa/simple/ov5675.yaml \
         /usr/share/libcamera/ipa/simple/ov5675.yaml; do
    if [ -f "$y" ] && grep -q '^\s*-\?\s*Ccm:' "$y"; then
        echo "ERROR: a CCM is already installed in $y" >&2
        echo "       Remove it first (sudo tools/install-ccm.sh revert)," >&2
        echo "       otherwise you would be tuning a correction on top of a" >&2
        echo "       correction and the preview would not match the camera." >&2
        exit 1
    fi
done

echo "== capturing =="
timeout 40 gst-launch-1.0 -q v4l2src device="$LOOPBACK" \
    ! videoconvert ! videorate ! video/x-raw,framerate=2/1 \
    ! identity eos-after=8 ! pngenc \
    ! multifilesink location="$T/f-%02d.png" >/dev/null 2>&1

# Take the last frame: the first few are captured while AGC/AWB are still
# settling and are not representative.
last="$(ls "$T"/f-*.png 2>/dev/null | tail -1)"
[ -n "$last" ] || { echo "no frames - is /dev/video0 free? try: fuser -v /dev/video0" >&2; exit 1; }
cp "$last" "$CAP"
echo "   captured $CAP"

echo
echo "== scene check =="
# A usable tuning frame needs BOTH a strongly coloured region to judge and a
# neutral region for AWB to lock onto. Grey-world AWB always drives the frame
# mean to neutral, so "the mean is neutral" proves nothing - if the subject
# fills the frame, what gets neutralised is the subject's own colour, and no
# matrix fitted to that frame will be right.
python3 - "$CAP" <<'PY'
import sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image

im = Image.open(sys.argv[1]).convert("RGB")
px = list(im.getdata())[::7]          # subsample; this is a sanity check

n = len(px)
tot = 0.0
strong = 0        # pixels with real colour, to judge the matrix on
whiteref = 0      # BRIGHT near-neutral pixels, i.e. an actual white reference
for r, g, b in px:
    mx, mn = max(r, g, b), min(r, g, b)
    sat = 0.0 if mx == 0 else (mx - mn) / mx
    tot += (r + g + b) / 3
    if sat > 0.30:
        strong += 1
    elif mx > 153 and sat < 0.12:
        whiteref += 1

bright = tot / n / 255
strong /= n
whiteref /= n

# Counting all near-neutral pixels does not work here: when the subject fills
# the frame, AWB neutralises the subject itself, and those dark washed-out
# pixels then read as "neutral reference" and mask the very fault being looked
# for. A genuine white reference is neutral AND bright, hence the mx > 153.
# Veiling flare check. A dark subject against a large brightly lit background
# lifts the whole shadow floor, and because the AWB is applying ~4.9x to blue,
# that lift arrives violet. Every dark colour then reads purple and no matrix
# can undo it - the error is added light, not a channel mixing error. Measured
# on the frame's own darkest pixels, which should approach black.
darkest = sorted(px, key=sum)[:max(1, len(px) // 100)]
fr = sum(p[0] for p in darkest) / len(darkest)
fg = sum(p[1] for p in darkest) / len(darkest)
fb = sum(p[2] for p in darkest) / len(darkest)
floor = (fr + fg + fb) / 3 / 255
floor_cast = (max(fr, fg, fb) - min(fr, fg, fb)) / 255

print(f"  brightness            {bright*100:4.0f}%   want 35-70%")
print(f"  strongly coloured     {strong*100:4.0f}%   want >10%")
print(f"  white reference       {whiteref*100:4.0f}%   want >8% (bright AND neutral)")
print(f"  black floor           {floor*100:4.0f}%   want <18% (flare lifts it)")
print(f"  black floor cast      {floor_cast*100:4.0f}%   want <12% "
      f"(R{fr:.0f} G{fg:.0f} B{fb:.0f})")

bad = []
if bright < 0.30:
    bad.append("too dark - add light")
elif bright > 0.75:
    bad.append("too bright - highlights will clip and hide the colour")
if strong < 0.10:
    bad.append("no strongly coloured region to tune against")
if whiteref < 0.08:
    bad.append("nothing bright and neutral in shot - the subject is filling "
               "the frame and grey-world AWB is neutralising its colour. Pull "
               "back so a white wall or desk shows around it")
warn = []
flare_msg = ("shadows lifted by flare (black floor is not black). The subject "
             "is too small against too much bright background. Move closer so "
             "it fills 40-50% of the frame, and keep a dark subject off a big "
             "brightly lit wall")
if floor > 0.25 or floor_cast > 0.20:
    bad.append(flare_msg)
elif floor > 0.18 or floor_cast > 0.12:
    warn.append(flare_msg + " - tunable, but the result will be conservative")

print()
if bad:
    print("  NOT USABLE for tuning:")
    for b in bad:
        print(f"    - {b}")
    sys.exit(2)
for w in warn:
    print(f"  WARNING: {w}")
print("  usable")
PY
rc=$?
if [ $rc -ne 0 ]; then
    echo
    echo "Re-frame and run again. Rendering anyway would give you a matrix"
    echo "fitted to a scene the camera never really saw."
    exit $rc
fi

echo
echo "== rendering candidates =="
python3 "$HERE/try-ccm.py" "$CAP" "$OUT" "$@"
