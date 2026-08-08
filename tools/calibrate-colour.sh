#!/bin/bash
# Fix the green tint by measuring colour gains and pinning them.
#
# WHY NOT A TUNING FILE / CCM
#
# Measured on this machine, in LINEAR light:
#
#   sensor native      R/G 0.361   B/G 0.724
#   after libcamera    R/G 0.504   B/G 0.899     (neutral would be 1.000)
#
# libcamera's soft-ISP AWB is grey-world targeting unity and symmetric in R/B,
# so it should reach 1.000 whatever the scene - but it applies only red x1.40
# where x2.77 is needed. A CCM corrects hue *after* white balance and cannot
# rescue a white balance that is off by 2x. So: disable the AWB, pin measured
# gains.
#
# WHY A SYSTEMD DROP-IN RATHER THAN VIDEOSRC
#
# colour-gains needs GstValueArray syntax, <r,b>. Putting that in VIDEOSRC does
# not survive EnvironmentFile parsing plus ExecStart expansion - /bin/sh ends up
# seeing a bare '<' and treats it as input redirection:
#
#   /bin/sh: 1: cannot open 2.77,1.38: No such file
#
# A drop-in that overrides ExecStart outright has no variable expansion in that
# position, so the brackets sit inside double quotes and reach GStreamer intact.
#
# LIMITATION
#
# Fixed gains do not adapt to changing light. They are calibrated for whatever
# you run this under; re-run after a big lighting change. The real fix belongs
# upstream in libcamera's AWB.
#
# Point the camera at a NEUTRAL, evenly lit surface filling the frame - a white
# or grey wall, or a sheet of paper. NOT a colour palette: the calibration
# assumes what it sees is grey.
#
# Run as root:  sudo ./calibrate-colour.sh          measure, then apply
#               sudo ./calibrate-colour.sh measure  measure only
#               sudo ./calibrate-colour.sh revert   back to automatic AWB

set -u

CONF=/etc/v4l2-relayd.d/default.conf
DROPIN_DIR=/etc/systemd/system/v4l2-relayd@.service.d
DROPIN="$DROPIN_DIR/20-colour-gains.conf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

MODE="${1:-apply}"

restore_videosrc() {
    # Undo the broken in-VIDEOSRC attempt from the earlier version of this
    # script, if it is still there.
    if grep -q 'colour-gains' "$CONF" 2>/dev/null; then
        sed -i -e 's| awb-enable=false||' -e 's| colour-gains="\?<[^>]*>"\?||' "$CONF"
        echo "  cleaned colour settings out of VIDEOSRC"
    fi
}

if [ "$MODE" = "revert" ]; then
    echo "== reverting =="
    restore_videosrc
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed v4l2-relayd@default.service 2>/dev/null || true
    systemctl restart v4l2-relayd.service
    sleep 4
    systemctl is-active v4l2-relayd@default.service || true
    exit 0
fi

# Always clear the broken form before doing anything else.
restore_videosrc

# shellcheck disable=SC1090
. "$CONF"

measure() {   # $1 red gain, $2 blue gain -> "R/G B/G" in linear light, or "0 0"
    rm -f "$TMP"/m-*.png
    # identity eos-after, because multifilesink has no num-buffers (that is a
    # GstBaseSrc property) and libcamerasrc has none either. videorate first so
    # a few seconds of settling costs a handful of PNGs rather than a hundred.
    timeout 45 gst-launch-1.0 -q \
        libcamerasrc awb-enable=false colour-gains="<$1,$2>" \
        ! video/x-raw,width="$WIDTH",height="$HEIGHT" \
        ! videoconvert ! videorate ! video/x-raw,framerate=2/1 \
        ! identity eos-after=8 ! pngenc \
        ! multifilesink location="$TMP/m-%02d.png" >/dev/null 2>&1
    python3 - "$TMP" <<'PY'
import glob, sys, warnings
warnings.filterwarnings("ignore")
from PIL import Image
fs = sorted(glob.glob(sys.argv[1] + "/m-*.png"))
if not fs:
    print("0 0"); raise SystemExit
lut = [(c/255.0/12.92 if c/255.0 <= 0.04045 else ((c/255.0+0.055)/1.055)**2.4)
       for c in range(256)]
im = Image.open(fs[-1]).convert("RGB")
px = list(im.getdata())[::97]
n = len(px)
r = sum(lut[p[0]] for p in px)/n
g = sum(lut[p[1]] for p in px)/n
b = sum(lut[p[2]] for p in px)/n
print(f"{r/g:.4f} {b/g:.4f}" if g > 0.002 else "0 0")
PY
}

echo "== stopping v4l2-relayd for exclusive access =="
systemctl stop v4l2-relayd.service
sleep 2

red=2.77
blue=1.38
ok=0
echo
echo "== converging (target R/G = B/G = 1.000) =="
for i in 1 2 3 4 5; do
    read -r rg bgr <<<"$(measure "$red" "$blue")"
    if [ "$rg" = "0" ]; then
        echo "  round $i: no frames captured"
        break
    fi
    printf '  round %d: gains r=%-6s b=%-6s ->  R/G %s  B/G %s\n' \
        "$i" "$red" "$blue" "$rg" "$bgr"
    ok=1
    read -r red blue <<<"$(python3 -c "
r,b=$red,$blue; rg,bg=$rg,$bgr
print(f'{min(max(r/rg,1.0),8.0):.3f} {min(max(b/bg,1.0),8.0):.3f}')")"
done

if [ "$ok" -eq 0 ]; then
    # Fail closed. The previous version wrote its unverified starting estimate
    # here and broke the service; never apply a number that was not measured.
    echo
    echo "MEASUREMENT FAILED - not changing anything." >&2
    echo "Check the camera is free and try:  gst-launch-1.0 -v libcamerasrc ! fakesink num-buffers=5" >&2
    systemctl start v4l2-relayd.service
    exit 1
fi

echo
echo "== final gains: red=$red blue=$blue =="

if [ "$MODE" = "measure" ]; then
    echo "(measure only, nothing changed)"
    systemctl start v4l2-relayd.service
    exit 0
fi

mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
[Service]
# Overrides ExecStart so colour-gains=<r,b> survives: no variable expansion
# happens in this position, so the angle brackets stay inside double quotes and
# /bin/sh does not read them as redirection.
ExecStart=
ExecStart=/bin/sh -c 'DEVICE=\$(grep -l -m1 -F "$CARD_LABEL" /sys/devices/virtual/video4linux/*/name | cut -d/ -f6); exec /usr/bin/v4l2-relayd -i "libcamerasrc awb-enable=false colour-gains=<$red,$blue> ! video/x-raw,width=$WIDTH,height=$HEIGHT ! videoconvert" -o "appsrc name=appsrc caps=video/x-raw,format=$FORMAT,width=$WIDTH,height=$HEIGHT,framerate=$FRAMERATE ! videoconvert ! v4l2sink name=v4l2sink device=/dev/\$\$DEVICE"'
EOF
echo "== drop-in =="
sed 's/^/  /' "$DROPIN"

systemctl daemon-reload
systemctl reset-failed v4l2-relayd@default.service 2>/dev/null || true
systemctl start v4l2-relayd.service
sleep 5
printf '\nservice: '
systemctl is-active v4l2-relayd@default.service || {
    echo "FAILED - reverting"
    "$0" revert
    exit 1
}
echo "Check the camera. Revert with: sudo $0 revert"
