#!/bin/bash
# Build libcamera with RGB-IR mosaic support and switch the relay to it.
#
# WHAT THIS DOES
#
# Adds a pre-pass to the CPU debayer that converts the sensor's 4x4 RGB-IR
# mosaic into a valid 2x2 Bayer image of the same dimensions, so everything
# downstream - debayer, statistics, AWB, CCM, gamma - works unmodified. See
# libcamera-rgbir/ and defect 5 in the README.
#
# It is gated on the LIBCAMERA_RGBIR environment variable. Without that set,
# the build behaves exactly as before, so installing this cannot break a
# working camera on its own.
#
# RGB-IR needs the unbinned sensor mode - binning averages infrared pixels in
# with colour ones - so the relay is also switched to capture at full
# resolution and scale down, and to the CPU debayer, which is where the
# pre-pass lives.
#
# Run as root:
#   sudo ./install-rgbir.sh build     patch the source and rebuild libcamera
#   sudo ./install-rgbir.sh enable    install it and switch the relay over
#   sudo ./install-rgbir.sh disable   back to the current pipeline, keeps build
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
USER_HOME="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
SRC="${USER_HOME:-$HOME}/.cache/libcamera-build/libcamera-src"
ISP="$SRC/src/libcamera/software_isp"
DROPIN_DIR=/etc/systemd/system/v4l2-relayd@.service.d
RGBIR_CONF="$DROPIN_DIR/50-rgbir.conf"
# Same detection as fix-browser-camera.sh and tune-relay-pipeline.sh: the
# per-instance file exists only on the Dell OEM image, while a stock Ubuntu
# install keeps the config in /etc/default. Hardcoding the first made `enable`
# abort part-way - after installing libcamera but before setting VIDEOSRC and
# the environment - so the pre-pass silently never ran and the diagnostic
# logged nothing, which looks exactly like the pre-pass being broken.
RELAY_CONF=""
for c in /etc/v4l2-relayd.d/default.conf /etc/default/v4l2-relayd; do
    [ -f "$c" ] && RELAY_CONF="$c"
done
[ -n "$RELAY_CONF" ] || { echo "ERROR: no v4l2-relayd config found" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

case "${1:-}" in
build)
    [ -d "$ISP" ] || { echo "ERROR: no libcamera source at $SRC" >&2
                       echo "       run tools/build-libcamera.sh build first" >&2; exit 1; }

    echo "== staging the converter =="
    install -m644 "$REPO/libcamera-rgbir/rgbir_to_bayer.h" "$ISP/"
    install -m644 "$REPO/libcamera-rgbir/rgbir_to_bayer.cpp" "$ISP/"

    echo "== patching meson.build =="
    python3 - "$ISP/meson.build" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if "rgbir_to_bayer.cpp" not in s:
    s = s.replace("    'debayer_cpu.cpp',", "    'debayer_cpu.cpp',\n    'rgbir_to_bayer.cpp',")
    open(p, "w").write(s)
    print("   added")
else:
    print("   already there")
PY

    echo "== patching debayer_cpu =="
    python3 - "$ISP/debayer_cpu.h" "$ISP/debayer_cpu.cpp" <<'PY'
import sys, os, stat

def writable(p):
    try:
        os.chmod(p, os.stat(p).st_mode | stat.S_IWUSR)
    except PermissionError:
        pass

hp, cp = sys.argv[1], sys.argv[2]

h = open(hp).read()
if "rgbIr_" not in h:
    h = h.replace('#include "debayer.h"',
                  '#include "debayer.h"\n#include "rgbir_to_bayer.h"')
    # Members. Placed with the other per-configuration state.
    h = h.replace("\tRectangle window_;",
                  "\tRectangle window_;\n"
                  "\t/* RGB-IR pre-pass, enabled by LIBCAMERA_RGBIR. */\n"
                  "\tstd::unique_ptr<RgbIrToBayer> rgbIr_;\n"
                  "\tstd::vector<uint16_t> rgbIrScratch_;\n"
                  "\tSize rgbIrInputSize_;\n"
                  "\tRgbIrToBayer::Order rgbIrOrder_ = RgbIrToBayer::Order::GRBG;")
    writable(hp); open(hp, "w").write(h)
    print("   header patched")
else:
    print("   header already patched")

c = open(cp).read()
if "rgbIr_" not in c:
    # secure_getenv lives here; do not rely on it arriving transitively.
    if "base/utils.h" not in c:
        c = c.replace('#include <libcamera/formats.h>',
                      '#include <libcamera/base/utils.h>\n\n#include <libcamera/formats.h>')
    # Construct in configure(), once the input format is known.
    anchor = "\tinputConfig_.stride = inputCfg.stride;"
    assert anchor in c, "configure() anchor not found"
    c = c.replace(anchor, anchor + '''

	/*
	 * Optional RGB-IR pre-pass. This sensor's mosaic is 4x4 with one pixel
	 * in four infrared; read as 2x2 Bayer the "blue" channel is pure IR
	 * and "red" interleaves real red with real blue. Convert to a same-size
	 * Bayer image first so everything below is unchanged.
	 *
	 * Gated on an environment variable because there is no way to describe
	 * an RGB-IR sensor in the V4L2 ABI yet, so libcamera cannot know.
	 */
	rgbIr_.reset();
	if (utils::secure_getenv("LIBCAMERA_RGBIR")) {
		BayerFormat bayer = BayerFormat::fromPixelFormat(inputCfg.pixelFormat);
		rgbIrOrder_ = bayer.order == BayerFormat::GBRG
				    ? RgbIrToBayer::Order::GBRG
				    : RgbIrToBayer::Order::GRBG;
		rgbIrInputSize_ = inputCfg.size;
		using Ch = RgbIrToBayer::Channel;
		static const Ch pattern[16] = {
			Ch::Green, Ch::Infrared, Ch::Green, Ch::Infrared,
			Ch::Red,   Ch::Green,    Ch::Blue,  Ch::Green,
			Ch::Green, Ch::Infrared, Ch::Green, Ch::Infrared,
			Ch::Blue,  Ch::Green,    Ch::Red,   Ch::Green,
		};
		rgbIr_ = std::make_unique<RgbIrToBayer>(pattern, 64, 10);
		rgbIrScratch_.resize(static_cast<size_t>(inputCfg.size.height) *
				     inputCfg.stride / 2);
		LOG(Debayer, Info)
			<< "RGB-IR pre-pass enabled, " << inputCfg.size
			<< ", emitting "
			<< (rgbIrOrder_ == RgbIrToBayer::Order::GBRG ? "GBRG" : "GRBG");
	}''')

    # Use it in process(), between mapping the input and debayering.
    old = """	stats_->startFrame(frame);

	if (inputConfig_.patternSize.height == 2)
		process2(frame, in.planes()[0].data(), out.planes()[0].data());
	else
		process4(frame, in.planes()[0].data(), out.planes()[0].data());"""
    new = """	stats_->startFrame(frame);

	const uint8_t *srcData = in.planes()[0].data();
	if (rgbIr_) {
		int ret = rgbIr_->convertSameSize(srcData,
						  rgbIrInputSize_.width,
						  rgbIrInputSize_.height,
						  inputConfig_.stride,
						  rgbIrScratch_.data(),
						  inputConfig_.stride,
						  rgbIrOrder_);
		if (ret == 0)
			srcData = reinterpret_cast<const uint8_t *>(rgbIrScratch_.data());
		else
			LOG(Debayer, Error) << "RGB-IR conversion failed: " << ret;
	}

	if (inputConfig_.patternSize.height == 2)
		process2(frame, srcData, out.planes()[0].data());
	else
		process4(frame, srcData, out.planes()[0].data());"""
    assert old in c, "process() anchor not found"
    c = c.replace(old, new)
    writable(cp); open(cp, "w").write(c)
    print("   source patched")
else:
    print("   source already patched")
PY

    echo
    echo "== building =="
    ninja -C "$SRC/build"
    echo
    echo "Built. Now: sudo $0 enable"
    ;;

enable)
    cd "$SRC" && ninja -C build install && ldconfig

    # RGB-IR needs the unbinned mode, and the pre-pass lives in the CPU debayer.
    mkdir -p "$DROPIN_DIR"
    cat > "$RGBIR_CONF" <<EOF
[Service]
Environment=LIBCAMERA_RGBIR=1
Environment=LIBCAMERA_SOFTISP_MODE=cpu
EOF

    cp -a "$RELAY_CONF" "$RELAY_CONF.before-rgbir"
    cur="$(sed -n 's/^VIDEOSRC=//p' "$RELAY_CONF" | tail -1)"
    # Capture full resolution, then scale to the relay's output size. Binning
    # would destroy the mosaic, so the sensor mode is not negotiable.
    new='libcamerasrc ! video/x-raw,width=2584,height=1944 ! videoscale ! video/x-raw,width=1280,height=720 ! videoconvert'
    sed -i "s|^VIDEOSRC=.*|VIDEOSRC=$new|" "$RELAY_CONF"
    echo "  VIDEOSRC=$new"
    echo "  (previous kept at $RELAY_CONF.before-rgbir)"

    systemctl daemon-reload
    systemctl restart v4l2-relayd.service
    sleep 8
    printf 'service: '
    systemctl is-active v4l2-relayd@default.service || true
    echo
    echo "Check the picture. If it is worse or broken: sudo $0 disable"
    ;;

disable)
    rm -f "$RGBIR_CONF"
    [ -f "$RELAY_CONF.before-rgbir" ] && mv "$RELAY_CONF.before-rgbir" "$RELAY_CONF"
    systemctl daemon-reload
    systemctl restart v4l2-relayd.service
    sleep 6
    printf 'service: '
    systemctl is-active v4l2-relayd@default.service || true
    echo "reverted (the patched libcamera stays installed but is inert)"
    ;;

*)
    sed -n '2,30p' "$0"
    exit 1
    ;;
esac
