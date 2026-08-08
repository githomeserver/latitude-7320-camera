#!/bin/bash
# Set the live saturation knob on the relay's libcamerasrc.
#
# REQUIRES A CCM TO BE INSTALLED FIRST. The control is gated on ccmEnabled,
# which only Ccm::init sets - see install-ccm.sh for the detail. Without one
# this appears to work and changes nothing.
#
# saturation is a plain float, so unlike colour-gains (which needs GstValueArray
# "<r,b>" syntax and gets mangled by systemd expanding it into /bin/sh, where
# "<" is a redirection) it can go straight into VIDEOSRC.
#
# Run as root:  sudo ./set-saturation.sh 1.8
#               sudo ./set-saturation.sh revert    back to default (1.0)

set -eu

CONF=/etc/v4l2-relayd.d/default.conf
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
V="${1:-}"
[ -n "$V" ] || { sed -n '2,14p' "$0"; exit 1; }

ccm_installed() {
    for y in /usr/local/share/libcamera/ipa/simple/ov5675.yaml \
             /usr/share/libcamera/ipa/simple/ov5675.yaml; do
        [ -f "$y" ] && grep -q 'Ccm:' "$y" && return 0
    done
    return 1
}

if [ "$V" != "revert" ] && ! ccm_installed; then
    echo "ERROR: no CCM in the tuning file, so the saturation control is inert." >&2
    echo "       Run: sudo tools/install-ccm.sh identity" >&2
    exit 1
fi

# Read VIDEOSRC without sourcing the file: it contains '!' and unquoted GStreamer
# syntax, and sourcing it has broken before (CARD_LABEL: unbound variable).
cur="$(sed -n 's/^VIDEOSRC=//p' "$CONF" | tail -1)"
[ -n "$cur" ] || { echo "ERROR: no VIDEOSRC in $CONF" >&2; exit 1; }

# Strip any saturation already present, quoted or not, then re-add.
new="$(printf '%s' "$cur" | sed -E 's/ saturation=[0-9.]+//g')"
if [ "$V" != "revert" ]; then
    case "$V" in
        ''|*[!0-9.]*) echo "ERROR: saturation must be a number, got '$V'" >&2; exit 1 ;;
    esac
    new="$(printf '%s' "$new" | sed -E "s/^(\"?)libcamerasrc/\1libcamerasrc saturation=$V/")"
fi

cp -a "$CONF" "$CONF.bak"
sed -i "s|^VIDEOSRC=.*|VIDEOSRC=$new|" "$CONF"
echo "VIDEOSRC=$new"

systemctl restart v4l2-relayd.service
sleep 6
printf 'service: '
systemctl is-active v4l2-relayd@default.service || true
