#!/bin/bash
# Build a patched libcamera into /usr/local and point v4l2-relayd at it.
#
# WHAT IT FIXES
#
# libcamera 0.7.0's soft-ISP AWB clamps colour gains at a hardcoded 4.0:
#
#   sum.r() <= sum.g() / 4 ? 4.0f : static_cast<float>(sum.g()) / sum.r(),
#
# This sensor needs a red gain of 6.1, so red is pinned at 4.0 on every frame
# (confirmed in the IPA debug log) and the image keeps a cyan cast. The patch
# drops the ceiling, matching what AwbGrey in libipa already does upstream.
#
# WHY /usr/local
#
# Nothing under /usr is touched, so the distro packages stay intact and this is
# undone by deleting one directory and one drop-in. It also sidesteps the IPA
# signature problem: libcamera signs IPA modules at build time and verifies
# them at load, so dropping a rebuilt .so next to the distro's signed one would
# fail verification. A self-contained build signs its own IPA with its own key.
#
# Run as root:  sudo ./build-libcamera.sh deps     install build dependencies
#               sudo ./build-libcamera.sh build    fetch, patch, compile
#               sudo ./build-libcamera.sh install  install + point the relay at it
#               sudo ./build-libcamera.sh revert   back to the distro libcamera

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHDIR="$HERE/../libcamera-patch"
USER_HOME="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
WORK="${USER_HOME:-$HOME}/.cache/libcamera-build"
PREFIX=/usr/local
DROPIN_DIR=/etc/systemd/system/v4l2-relayd@.service.d
DROPIN="$DROPIN_DIR/30-local-libcamera.conf"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

case "${1:-}" in
deps)
    echo "== enabling deb-src (needed for apt build-dep / apt source) =="
    S=/etc/apt/sources.list.d/ubuntu.sources
    if ! grep -q '^Types:.*deb-src' "$S"; then
        cp -a "$S" /etc/apt/ubuntu.sources.before-libcamera
        sed -i 's/^Types: deb$/Types: deb deb-src/' "$S"
        echo "   patched $S (backup at /etc/apt/ubuntu.sources.before-libcamera)"
    else
        echo "   already enabled"
    fi
    apt-get update
    echo
    echo "== build dependencies =="
    apt-get install -y meson ninja-build pkg-config git
    apt-get build-dep -y libcamera
    echo
    echo "Now: sudo $0 build"
    ;;

build)
    [ -f "$PATCHFILE" ] || { echo "ERROR: $PATCHFILE missing" >&2; exit 1; }
    mkdir -p "$WORK"
    cd "$WORK"
    if [ ! -d libcamera-src ]; then
        echo "== fetching the Ubuntu source for the installed version =="
        apt-get source libcamera
        d=$(find . -maxdepth 1 -type d -name 'libcamera-*' | head -1)
        [ -n "$d" ] || { echo "ERROR: apt-get source produced nothing" >&2; exit 1; }
        mv "$d" libcamera-src
    fi
    cd libcamera-src

        # Refuse an unusable source tree rather than failing four steps later.
        #
        # apt-get source fetches whatever the DISTRO ships, which on Ubuntu 24.04
        # is libcamera 0.2.0 - a tree with no software ISP at all, so no
        # src/ipa/simple/algorithms/ and no sensor/camera_sensor_properties.cpp.
        # Every patch step below then either misreported the missing file as
        # "already applied" or died in a Python traceback, several screens after
        # the real problem. Reported as issue #2, by someone who had to work out
        # for themselves that the distro source was too old.
        #
        # The layout this needs arrived in 0.7.x, which is what 26.04 ships, and
        # libcamera-rgbir/debayer_cpu.patch is generated against the v0.7.0 tag.
        LC_VER=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\''\([0-9.]*\)'\''.*/\1/p" meson.build | head -1)
        [ -n "$LC_VER" ] || LC_VER=unknown
        echo "== libcamera source version: $LC_VER =="
        case "${LC_VER%.*}" in
            0.7|0.8|0.9|1.*) ;;
            *)
                echo "ERROR: this needs libcamera 0.7.x; the source here is $LC_VER." >&2
                echo "       apt-get source fetches what the distro ships, and 0.7.x" >&2
                echo "       arrives with Ubuntu 26.04. On 24.04 you get 0.2.0, which" >&2
                echo "       has no software ISP - none of the files patched below" >&2
                echo "       exist in it. Upgrade, or supply a v0.7.0 checkout:" >&2
                echo "         git clone https://git.libcamera.org/libcamera/libcamera.git $WORK/libcamera-src" >&2
                echo "         git -C $WORK/libcamera-src checkout v0.7.0" >&2
                exit 1 ;;
        esac

        for f in src/ipa/simple/algorithms/awb.cpp \
                 src/libcamera/sensor/camera_sensor_properties.cpp; do
            [ -f "$f" ] || { echo "ERROR: $f is missing - the source layout is not 0.7.x." >&2
                             exit 1; }
        done

    echo
    echo "== applying the libcamera patches =="
    # Every patch in libcamera-patch/, in name order. This used to apply one
    # named file; a second patch was then easy to add to the repo and forget to
    # apply, which looks exactly like the fix not working.
    for pf in "$PATCHDIR"/[0-9]*.patch; do
        [ -f "$pf" ] || { echo "ERROR: no patches found in $PATCHDIR" >&2; exit 1; }
        name="$(basename "$pf")"
        if patch -p1 --dry-run --forward --force < "$pf" >/dev/null 2>&1; then
            patch -p1 --forward < "$pf" >/dev/null
            echo "   applied      $name"
        elif patch -p1 --dry-run --reverse --force < "$pf" >/dev/null 2>&1; then
            echo "   already in   $name"
        else
            # Neither cleanly appliable nor cleanly reversible. Reporting
            # "already applied (or the source differs)" here treated a tree that
            # does not match at all as success, which is how issue #2 got
            # several screens past the real problem.
            echo "ERROR: $name applies neither forward nor in reverse -" >&2
            echo "       this source tree is not what is expected." >&2
            exit 1
        fi
    done

    # Assert the effect, not just the exit status: a patch can apply with fuzz
    # into the wrong place.
    if grep -q '4.0f' src/ipa/simple/algorithms/awb.cpp; then
        echo "ERROR: a 4.0f gain clamp is still present in awb.cpp" >&2
        exit 1
    fi
    if grep -q 'SWSTATS_FINISH_LINE_STATS()' src/libcamera/software_isp/swstats_cpu.cpp; then
        echo "ERROR: swstats_cpu.cpp still sums in the input's own bit depth;" >&2
        echo "       the AWB will subtract an 8-bit black level from it." >&2
        exit 1
    fi
    echo "   verified: no gain clamp, stats sums scaled to 8 bits"

    echo
    echo "== applying the measured ov5675 sensor delays =="
    # Done as an in-place edit rather than with upstream-libcamera/0001-*.patch:
    # that patch is generated against the upstream git tree, where the ov5675
    # entry has no sensorDelays member at all, while Ubuntu's 0.7.0 source
    # already carries an empty ".sensorDelays = { }". The measured values are
    # the same either way - see tools/measure-sensor-delays.sh.
    python3 - <<'PY'
import re, os, stat, sys
f = "src/libcamera/sensor/camera_sensor_properties.cpp"
s = open(f).read()
m = re.search(r'\{ "ov5675", \{.*?\n\t\t\} \},', s, re.S)
if not m:
    sys.exit("   ERROR: could not find the ov5675 entry")
blk = m.group(0)
if "exposureDelay" in blk:
    print("   already applied")
    sys.exit(0)
new = blk.replace(
    "\t\t\t.sensorDelays = { },",
    "\t\t\t.sensorDelays = {\n"
    "\t\t\t\t.exposureDelay = 2,\n"
    "\t\t\t\t.gainDelay = 2,\n"
    "\t\t\t\t.vblankDelay = 2,\n"
    "\t\t\t\t.hblankDelay = 2,\n"
    "\t\t\t},")
if new == blk:
    sys.exit("   ERROR: ov5675 entry has no '.sensorDelays = { }' to replace")
try:                                             # apt source ships it read-only
    os.chmod(f, os.stat(f).st_mode | stat.S_IWUSR)
except PermissionError:
    pass                                         # root can write 0644 regardless
open(f, "w").write(s.replace(blk, new))
print("   applied: exposure/gain/vblank/hblank = 2 frames")
PY

    echo
    echo "== configuring (soft ISP + simple pipeline only, to keep it quick) =="
    rm -rf build
    meson setup build \
        --prefix="$PREFIX" \
        --buildtype=release \
        -Dwerror=false \
        -Dpipelines=simple \
        -Dipas=simple \
        -Dgstreamer=enabled \
        -Ddocumentation=disabled \
        -Dtest=false \
        -Dcam=enabled \
        -Dlc-compliance=disabled \
        -Dqcam=disabled

    echo
    echo "== building =="
    ninja -C build
    echo
    echo "Built. Now: sudo $0 install"
    ;;

install)
    cd "$WORK/libcamera-src"
    ninja -C build install
    ldconfig

    GST_DIR="$(find "$PREFIX/lib" -name 'libgstlibcamera*' -printf '%h\n' 2>/dev/null | head -1)"
    IPA_DIR="$(find "$PREFIX/lib" -type d -name ipa -path '*libcamera*' | head -1)"
    LIB_DIR="$(find "$PREFIX/lib" -name 'libcamera.so*' -printf '%h\n' 2>/dev/null | head -1)"
    echo
    echo "  gst plugin : ${GST_DIR:-NOT FOUND}"
    echo "  ipa modules: ${IPA_DIR:-NOT FOUND}"
    echo "  libraries  : ${LIB_DIR:-NOT FOUND}"

    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN" <<EOF
[Service]
# Use the locally built libcamera (AWB gain clamp removed) instead of the
# distro one. Nothing under /usr is modified; deleting this file reverts.
Environment=LD_LIBRARY_PATH=$LIB_DIR
Environment=LIBCAMERA_IPA_MODULE_PATH=$IPA_DIR
Environment=GST_PLUGIN_PATH=$GST_DIR
EOF
    sed 's/^/  /' "$DROPIN"
    systemctl daemon-reload
    systemctl restart ov5678-ondemand.service
    sleep 6
    printf '\nservice: '
    systemctl is-active ov5678-ondemand.service || true
    echo
    echo "Check the colour now. Revert with: sudo $0 revert"
    ;;

revert)
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart ov5678-ondemand.service
    echo "reverted to the distro libcamera (the /usr/local build is left in place)"
    ;;

*)
    sed -n '2,30p' "$0"
    exit 1
    ;;
esac
