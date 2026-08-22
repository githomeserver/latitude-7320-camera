#!/bin/bash
# Set the live saturation knob on the running camera pipeline.
#
# WHAT THIS EDITS, AND WHY IT CHANGED
#
# It rewrites the ExecStart of ov5678-camera.service, which is the unit that
# actually produces frames on this machine. It used to write VIDEOSRC= into
# /etc/v4l2-relayd.d/default.conf and restart v4l2-relayd - the relay this
# project replaced because it throttled the pipeline to 1.3 fps. On a current
# install that file does not exist and v4l2-relayd runs /bin/true, so the old
# version of this script could not have worked.
#
# saturation is a plain float, so unlike colour-gains (which needs GstValueArray
# "<r,b>" syntax and gets mangled by systemd expanding it into /bin/sh, where
# "<" is a redirection) it can go straight onto the libcamerasrc element.
#
# TWO THINGS MUST BE TRUE OR THIS SILENTLY DOES NOTHING
#
# A Ccm must be in the tuning file, and it must be listed BEFORE Adjust.
# Registration of controls::Saturation happens in Adjust::init and reads a flag
# that only Ccm::init sets, so with the entries the other way round the camera
# never advertises the control and the value is dropped before it reaches the
# IPA. Both are checked below rather than left to be discovered later, because
# the failure looks exactly like the knob having no effect. Measured with the
# matrix present but listed last: saturation 0.0, 1.0 and 2.0 all gave a mean
# chroma of 3.86. In the right order: 1.00, 4.01, 7.99.
#
# For a permanent setting, install it instead:
#   sudo SATURATION=1.6 tools/install-camera-service.sh
#
# Run as root:  sudo ./set-saturation.sh 1.6
#               sudo ./set-saturation.sh revert    back to default (1.0)

set -eu

UNIT=/etc/systemd/system/ov5678-camera.service
PRODUCER=ov5678-camera.service
SUPERVISOR=ov5678-ondemand.service

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
V="${1:-}"
[ -n "$V" ] || { sed -n '2,31p' "$0"; exit 1; }
[ -f "$UNIT" ] || { echo "ERROR: $UNIT not found - run tools/install-camera-service.sh first" >&2; exit 1; }

tuning() {
    for y in /usr/local/share/libcamera/ipa/simple/ov5675.yaml \
             /usr/share/libcamera/ipa/simple/ov5675.yaml; do
        [ -f "$y" ] && { echo "$y"; return 0; }
    done
    return 1
}

if [ "$V" != "revert" ]; then
    case "$V" in
        ''|*[!0-9.]*) echo "ERROR: saturation must be a number, got '$V'" >&2; exit 1 ;;
    esac
    Y="$(tuning)" || { echo "ERROR: no libcamera tuning file found" >&2; exit 1; }
    grep -q 'Ccm:' "$Y" || {
        echo "ERROR: no CCM in $Y, so the saturation control is inert." >&2
        echo "       Run: sudo tools/install-ccm.sh identity" >&2
        exit 1
    }
    # Order matters as much as presence - see the header.
    ccm_line=$(grep -n '^\s*- Ccm:' "$Y" | head -1 | cut -d: -f1)
    adj_line=$(grep -n '^\s*- Adjust:' "$Y" | head -1 | cut -d: -f1)
    if [ -n "$adj_line" ] && [ "$ccm_line" -gt "$adj_line" ]; then
        echo "ERROR: Ccm is listed AFTER Adjust in $Y, so controls::Saturation is" >&2
        echo "       never registered and this would do nothing." >&2
        echo "       Reinstall the matrix to fix the order: sudo tools/install-ccm.sh identity" >&2
        exit 1
    fi
fi

cur="$(sed -n 's/^ExecStart=//p' "$UNIT" | tail -1)"
[ -n "$cur" ] || { echo "ERROR: no ExecStart in $UNIT" >&2; exit 1; }

# Strip any saturation already there, then re-add after the element name.
new="$(printf '%s' "$cur" | sed -E 's/ saturation=[0-9.]+//g')"
if [ "$V" != "revert" ]; then
    new="$(printf '%s' "$new" | sed -E "s/libcamerasrc/libcamerasrc saturation=$V/")"
fi

cp -a "$UNIT" "$UNIT.bak"
# '|' as the delimiter: the command line is full of '/'.
sed -i "s|^ExecStart=.*|ExecStart=$new|" "$UNIT"
echo "ExecStart=$new"

systemctl daemon-reload
# The supervisor starts the producer on demand, so a restart is only needed if
# it happens to be running right now; otherwise the next start picks this up.
if systemctl is-active --quiet "$PRODUCER"; then
    systemctl restart "$PRODUCER"
    echo "restarted $PRODUCER"
else
    echo "$PRODUCER is idle; the new value applies next time something opens the camera"
fi
systemctl is-active --quiet "$SUPERVISOR" || echo "NOTE: $SUPERVISOR is not running"
