#!/bin/bash
# Capture the same subject at each stage of the pipeline, for the README.
#
# The point is that a reader can SEE what each install step buys them. Every
# frame is the same colour chart, same framing, same screen brightness, same
# output size - only the pipeline changes between them. Move the laptop or touch
# the screen brightness partway through and the series becomes a comparison of
# scenes rather than of code, which is worthless.
#
# Display data/ccm-target-16x9.png full screen, filling the camera's view, then:
#
#   sudo ./capture-progress-images.sh
#
# Writes data/progress-N-*.png. A colour chart is used rather than a room so the
# results are publishable.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/.." && pwd)"
OUT="$PROJ/data"
YAML=/usr/local/share/libcamera/ipa/simple/ov5675.yaml
MAP="$PROJ/data/lens-shading-measured-raw.bin"
FRAMES="${FRAMES:-45}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root" >&2; exit 1; }

systemctl stop ov5678-ondemand.service ov5678-camera.service \
               ov5678-placeholder.service 2>/dev/null
sleep 2

# The CCM lives in the tuning file, not an environment variable, so showing the
# before/after needs the file swapped. Keep the real one safe.
BACKUP="$(mktemp)"
cp "$YAML" "$BACKUP"
restore() { cp "$BACKUP" "$YAML"; rm -f "$BACKUP"; }
trap restore EXIT

shoot() {          # shoot <name> <env...>
    local name="$1"; shift
    env "$@" timeout 90 \
      gst-launch-1.0 -q libcamerasrc ! video/x-raw,width=1280,height=720 \
      ! identity eos-after="$FRAMES" ! videoconvert ! pngenc \
      ! multifilesink location="$OUT/progress-$name.png" >/dev/null 2>&1
    if [ -s "$OUT/progress-$name.png" ]; then
        echo "  $name: $(stat -c%s "$OUT/progress-$name.png") bytes"
    else
        echo "  $name: FAILED" >&2
    fi
}

OURS="LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu
LIBCAMERA_IPA_MODULE_PATH=/usr/local/lib/x86_64-linux-gnu/libcamera/ipa
LIBCAMERA_SOFTISP_MODE=cpu
LIBCAMERA_RGBIR=1
RGBIR_IRSUB=2.0"

echo "== 1. distro libcamera, no RGB-IR handling (what the quick start gives you) =="
# Deliberately WITHOUT our /usr/local build: the mosaic is read as plain Bayer.
shoot 1-quickstart -u LD_LIBRARY_PATH -u LIBCAMERA_IPA_MODULE_PATH -u GST_PLUGIN_PATH

echo "== 2. + RGB-IR pre-pass (identity matrix, nothing else) =="
"$HERE/install-ccm.sh" identity >/dev/null 2>&1
shoot 2-prepass $OURS RGBIR_SHARPNESS=0.0 RGBIR_DENOISE=1.0

echo "== 3. + colour matrix =="
cp "$BACKUP" "$YAML"
shoot 3-ccm $OURS RGBIR_SHARPNESS=0.0 RGBIR_DENOISE=1.0

echo "== 4. + lens shading =="
shoot 4-shading $OURS RGBIR_SHARPNESS=0.0 RGBIR_DENOISE=1.0 RGBIR_SHADING="$MAP"

echo "== 5. + temporal denoise =="
shoot 5-denoise $OURS RGBIR_SHARPNESS=0.0 RGBIR_DENOISE=0.15 RGBIR_SHADING="$MAP"

echo "== 6. + green detail =="
shoot 6-sharp $OURS RGBIR_SHARPNESS=0.5 RGBIR_DENOISE=0.15 RGBIR_SHADING="$MAP"

restore; trap - EXIT
systemctl start ov5678-ondemand.service 2>/dev/null
echo
echo "Done. Check every frame shows the chart before publishing any of them."
