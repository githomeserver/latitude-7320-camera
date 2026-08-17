#!/bin/bash
# Measure this unit's real lens falloff from a flat field, and check Intel's
# tables against it.
#
# WHY THIS NEEDS A FLAT FIELD, AND WHY THERE IS NO WAY AROUND IT.
#
# Vignetting is a multiplicative gain that varies across the frame. On an
# ordinary scene it is inseparable from the scene's own brightness variation:
# measured on a room with a window, this camera's corners read 1.03x the centre
# in linear light, which would say there is no falloff at all. The same frame
# with Intel's correction applied reads 2.53x, which would say it is wildly
# over-corrected. Both numbers are meaningless. Only a uniformly lit, uniformly
# coloured field makes the gain observable on its own.
#
# HOW TO SHOOT ONE
#
# Any of these, filling the whole frame with nothing in focus:
#   - a sheet of plain white paper held flat against the camera, lit from behind
#     you, no shadow across it
#   - a blank white full-screen window on a second monitor, camera close enough
#     that it fills the frame
#   - an evenly lit plain wall, close, camera square to it
#
# What matters is that no part of the frame is brighter than another for any
# reason other than the lens. Avoid: direct light sources in frame, glare,
# anything clipped to 255, and anything so dark it is in the noise.
#
# Usage:
#   sudo ./measure-lens-shading.sh            capture and report (processed frame)
#   sudo ./measure-lens-shading.sh --write    also write a measured gain map
#   sudo ./measure-lens-shading.sh --raw      RAW measurement - USE THIS ONE
#
# --raw is the only per-channel measurement that means anything. A processed
# frame has been through the CCM, whose red row here is 1.81R -0.345G -0.465B,
# so its "red" at the corner is a blend of all three sensor channels. Measured
# that way this camera looked like it needed LESS corner gain on red than on
# green, while every one of Intel's seven illuminants says more. The matrix
# produced that entire disagreement. The mosaic has one channel per pixel and
# no matrix has touched it.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"
OUT="${TMPDIR:-/tmp}/lens-shading-flat.png"
MAP="$PROJ/data/lens-shading-ov5678.bin"
MEASURED="$PROJ/data/lens-shading-measured.bin"
WRITE=0
RAW=0
case "${1:-}" in
    --write) WRITE=1 ;;
    --raw)   RAW=1 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

if [ "$RAW" = 1 ]; then
    RAWDIR="${TMPDIR:-/tmp}/lens-shading-raw"
    rm -rf "$RAWDIR"; mkdir -p "$RAWDIR"
    echo "== capturing 20 RAW flat-field frames =="
    systemctl stop ov5678-camera.service 2>/dev/null
    sleep 1
    env LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu \
        LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera/ipa \
      timeout 120 /usr/local/bin/cam -c1 -s role=raw -C20 --file="$RAWDIR/raw#.bin" \
      >/dev/null 2>&1
    systemctl start ov5678-camera.service 2>/dev/null
    n=$(ls "$RAWDIR"/rawcam0-stream0-*.bin 2>/dev/null | wc -l)
    echo "  captured $n frames"
    [ "$n" -gt 0 ] || { echo "ERROR: no raw frames" >&2; exit 1; }
    OUTMAP="$PROJ/data/lens-shading-measured-raw.bin"
    python3 "$HERE/measure-shading-raw.py" "$RAWDIR" --compare "$MAP" -o "$OUTMAP"
    rc=$?
    # Running under sudo makes anything written here root-owned, which then
    # makes the ordinary user's next run fail with EACCES on its own data
    # directory. Hand the files back.
    if [ -n "${SUDO_USER:-}" ]; then
        chown "$SUDO_USER" "$OUTMAP" 2>/dev/null
        chown "$SUDO_USER" "$PROJ/data"/*.bin "$PROJ/data"/*.png 2>/dev/null
    fi
    exit $rc
fi

echo "== capturing a flat field =="
systemctl stop ov5678-camera.service 2>/dev/null
sleep 1
# Shading correction MUST be off while measuring, or the measurement includes
# the correction and converges on nothing.
env LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu \
    LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera/ipa \
    GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0 \
    LIBCAMERA_RGBIR=1 RGBIR_IRSUB=1.0 RGBIR_SHARPNESS=0.0 RGBIR_DENOISE=0.15 \
    LIBCAMERA_SOFTISP_MODE=cpu \
  timeout 90 gst-launch-1.0 -q libcamerasrc ! video/x-raw,width=1280,height=720 \
    ! videoconvert ! pngenc ! multifilesink location="$OUT" >/dev/null 2>&1
systemctl start ov5678-camera.service 2>/dev/null

[ -s "$OUT" ] || { echo "ERROR: capture failed" >&2; exit 1; }
echo "  captured $OUT"

WRITE=$WRITE MAP="$MAP" MEASURED="$MEASURED" OUT="$OUT" python3 - <<'PY'
import os, struct, sys
from PIL import Image

out = os.environ["OUT"]
im = Image.open(out).convert("RGB")
w, h = im.size
px = im.load()

GRID_W, GRID_H = 63, 47          # match Intel's grid so the two are comparable
ONE = 2048

def lin(v):
    return (v / 255.0) ** 2.2

# Per-cell mean of each channel, in linear light, which is what a gain acts on.
cells = [[[0.0]*3 for _ in range(GRID_W)] for _ in range(GRID_H)]
for gy in range(GRID_H):
    y0, y1 = gy * h // GRID_H, (gy + 1) * h // GRID_H
    for gx in range(GRID_W):
        x0, x1 = gx * w // GRID_W, (gx + 1) * w // GRID_W
        acc = [0.0]*3; n = 0
        for y in range(y0, y1, 2):
            for x in range(x0, x1, 2):
                r, g, b = px[x, y]
                acc[0] += lin(r); acc[1] += lin(g); acc[2] += lin(b)
                n += 1
        cells[gy][gx] = [a/n for a in acc] if n else [0.0]*3

# Sanity: a usable flat field is neither clipped nor in the noise, and its
# brightest cell should be near the centre.
allv = [c[1] for row in cells for c in row]
gmax, gmin = max(allv), min(allv)
centre = cells[GRID_H//2][GRID_W//2][1]
corners = [cells[2][2][1], cells[2][-3][1], cells[-3][2][1], cells[-3][-3][1]]
cmean = sum(corners)/4
print(f"  centre (linear) {centre:.4f}   corners {cmean:.4f}   corner/centre {cmean/centre:.3f}")

bad = []
if centre < 0.02:  bad.append("too dark - the centre is down in the noise")
if centre > 0.85:  bad.append("too bright - the centre is close to clipping")
if gmax > 0.98:    bad.append("some cells are clipped at white")
if centre < gmax * 0.9:
    bad.append("the brightest area is not the centre, so this is not a flat field")
if bad:
    print("\n  NOT A USABLE FLAT FIELD:")
    for b in bad: print(f"    - {b}")
    print("  Re-shoot per the notes at the top of this script; nothing was written.")
    sys.exit(1)

need = centre / cmean
print(f"  this unit needs {need:.2f}x at the corners")

try:
    d = open(os.environ["MAP"], "rb").read()
    mw, mh, mone, nch = struct.unpack_from("<4H", d, 0)
    g = struct.unpack_from(f"<{mw*mh}H", d, 8)          # channel 0 = green
    ic = g[(mh//2)*mw + mw//2] / mone
    icorn = (g[2*mw + 2] + g[2*mw + mw - 3] +
             g[(mh-3)*mw + 2] + g[(mh-3)*mw + mw - 3]) / 4 / mone
    print(f"  Intel's table asks for {icorn/ic:.2f}x at the same points")
    ratio = (icorn/ic) / need
    verdict = "agrees" if 0.8 <= ratio <= 1.25 else "DISAGREES"
    print(f"  ratio Intel/measured = {ratio:.2f}  -> {verdict}")
except FileNotFoundError:
    print("  (Intel map not present, skipping the comparison)")

if os.environ.get("WRITE") == "1":
    chans = []
    for ci, gi in ((0, 1), (1, 1), (2, 0), (3, 2)):   # G, IR(copy G), R, B
        plane = []
        ref = cells[GRID_H//2][GRID_W//2][gi]
        for gy in range(GRID_H):
            for gx in range(GRID_W):
                v = cells[gy][gx][gi]
                gain = ref / v if v > 1e-6 else 1.0
                plane.append(max(ONE, min(int(gain * ONE), 8 * ONE)))
        chans.append(plane)
    with open(os.environ["MEASURED"], "wb") as f:
        f.write(struct.pack("<4H", GRID_W, GRID_H, ONE, 4))
        for p in chans:
            f.write(struct.pack(f"<{len(p)}H", *p))
    print(f"\n  wrote {os.environ['MEASURED']} from this unit's own falloff")
PY
