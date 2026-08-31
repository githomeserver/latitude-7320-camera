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
#   sudo ./install-rgbir.sh enable    install it (then install-camera-service.sh)
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
# v4l2-relayd is NOT part of this path any more - ov5678-camera.service replaced
# it, because the relay throttled the pipeline to 1.3 fps. The old config is only
# consulted by the obsolete enable/disable subcommands below, so nothing here may
# require it: demanding it up front made this script refuse to run at all on any
# machine that never had v4l2-relayd installed, which is every fresh machine.
RELAY_CONF=""
for c in /etc/v4l2-relayd.d/default.conf /etc/default/v4l2-relayd; do
    [ -f "$c" ] && RELAY_CONF="$c"
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

case "${1:-}" in
build)
    [ -d "$ISP" ] || { echo "ERROR: no libcamera source at $SRC" >&2
                       echo "       run tools/build-libcamera.sh build first" >&2; exit 1; }

    echo "== staging our sources =="
    for f in rgbir_to_bayer.h rgbir_to_bayer.cpp temporal_denoise.h temporal_denoise.cpp; do
        install -m644 "$REPO/libcamera-rgbir/$f" "$ISP/"
        echo "   $f"
    done

    echo "== patching meson.build =="
    python3 - "$ISP/meson.build" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
add = [f for f in ("rgbir_to_bayer.cpp", "temporal_denoise.cpp") if f not in s]
if add:
    ins = "".join(f"\n    '{f}'," for f in add)
    s = s.replace("    'debayer_cpu.cpp',", "    'debayer_cpu.cpp'," + ins)
    open(p, "w").write(s)
    print("   added " + ", ".join(add))
else:
    print("   already there")
PY

    # debayer_cpu is patched from a diff, not edited in place by string
    # replacement.
    #
    # It used to be a long series of s.replace() calls against a pristine file.
    # That silently stopped covering the work: six separate changes - the
    # adaptive IR coefficient, the denoise gain map, the per-band conversion,
    # the chroma blur, the CCM highlight rolloff and the coefficient logging -
    # were live in the build tree and reproduced by NONE of them. A fresh clone
    # built a libcamera with the committed sources present and unused, which is
    # the worst kind of wrong: the code is in git, so nothing looks missing.
    #
    # The patch is generated against the v0.7.0 tag and verified to reproduce
    # the working tree byte for byte. If libcamera moves on it will fail to
    # apply, loudly, which is the correct outcome - a silent partial apply is
    # what got us here.
    echo "== patching debayer_cpu =="
    PATCH="$REPO/libcamera-rgbir/debayer_cpu.patch"
    [ -f "$PATCH" ] || { echo "ERROR: missing $PATCH" >&2; exit 1; }
    if patch -s -p4 -R --dry-run -d "$ISP" < "$PATCH" >/dev/null 2>&1; then
        echo "   already applied"
        # An already-patched tree may also have been EDITED since. That is how
        # the patch went stale twice: work lived only in ~/.cache while every
        # source file in git looked correct. Say so here rather than let a later
        # clone build something quietly different.
        if [ -x "$HERE/refresh-debayer-patch.sh" ]; then
            "$HERE/refresh-debayer-patch.sh" --check >/dev/null 2>&1 || {
                echo
                echo "   WARNING: the build tree has changes the committed patch does not."
                echo "            Run: tools/refresh-debayer-patch.sh"
                echo
            }
        fi
    elif patch -s -p4 -d "$ISP" < "$PATCH"; then
        echo "   applied"
    else
        echo "ERROR: debayer_cpu.patch did not apply." >&2
        echo "       The libcamera source is probably not v0.7.0. Regenerate with:" >&2
        echo "         diff -u <v0.7.0 file> <working file>" >&2
        exit 1
    fi

    echo
    echo "== building =="
    ninja -C "$SRC/build"
    echo
    echo "Built. Now: sudo $0 enable"
    ;;

enable)
    cd "$SRC" && ninja -C build install && ldconfig
    echo
    echo "Installed. The pre-pass is gated on LIBCAMERA_RGBIR=1, which"
    echo "tools/install-camera-service.sh puts in the unit for you:"
    echo
    echo "  sudo tools/install-camera-service.sh"
    echo
    echo "Nothing here touches v4l2-relayd. ov5678-camera.service replaced it."
    ;;

relay-enable|relay-disable)
    # The original relay path, kept only for a machine still running
    # v4l2-relayd. On a current install use ov5678-camera.service instead.
    [ -n "$RELAY_CONF" ] || { echo "ERROR: no v4l2-relayd config found" >&2; exit 1; }
    if [ "${1:-}" = "relay-enable" ]; then
        mkdir -p "$DROPIN_DIR"
        printf '[Service]\nEnvironment=LIBCAMERA_RGBIR=1\nEnvironment=LIBCAMERA_SOFTISP_MODE=cpu\n' > "$RGBIR_CONF"
        cp -a "$RELAY_CONF" "$RELAY_CONF.before-rgbir"
        # Full resolution then scale: binning averages infrared in with colour
        # and destroys the mosaic, so the sensor mode is not negotiable.
        new='libcamerasrc ! video/x-raw,width=2584,height=1944 ! videoscale ! video/x-raw,width=1280,height=720 ! videoconvert'
        sed -i "s|^VIDEOSRC=.*|VIDEOSRC=$new|" "$RELAY_CONF"
        echo "  VIDEOSRC=$new"
    else
        rm -f "$RGBIR_CONF"
        [ -f "$RELAY_CONF.before-rgbir" ] && mv "$RELAY_CONF.before-rgbir" "$RELAY_CONF"
        echo "  reverted"
    fi
    systemctl daemon-reload
    systemctl restart ov5678-ondemand.service
    ;;

*)
    sed -n '2,30p' "$0"
    exit 1
    ;;
esac
