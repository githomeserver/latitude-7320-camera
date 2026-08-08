#!/bin/bash
# Hide the IPU6's 64 raw ISYS capture nodes from user applications.
#
# WHY
#
# The IPU6 exposes /dev/video1../dev/video64 as raw Bayer sinks feeding the
# ISP. None can serve a webcam request, but every app that scans /dev/video*
# lists them, so Firefox offers dozens of dead "ipu6" entries. The one that
# works is /dev/video0, the v4l2loopback "Intel MIPI Camera".
#
# Ubuntu ships a rule that is meant to handle this:
#
#   /usr/lib/udev/rules.d/72-intel-mipi-ipu6-camera.rules
#   SUBSYSTEM=="video4linux", ENV{ID_V4L_PRODUCT}=="ipu6", TAG-="uaccess"
#
# It works as far as it goes - the raw nodes carry no ACL while /dev/video0
# does - but it is defeated by group membership: the nodes are
# "crw-rw---- root video" and the desktop user is in the video group, so
# permission is granted anyway.
#
# So also take them out of the video group. /dev/video0 is untouched: it is
# ID_V4L_PRODUCT="Intel MIPI Camera", not "ipu6".
#
# TRADE-OFF
#
# v4l2-relayd runs as root, so the camera keeps working everywhere. But
# user-run libcamera (cam, and wireplumber's libcamera monitor) needs these
# nodes, so `cam` will need sudo afterwards and the duplicate "ov5675"
# [libcamera] entry disappears from PipeWire. If you would rather keep `cam`
# working without sudo, do not apply this - the cost is the cluttered list.
#
# Run as root:  sudo ./hide-raw-ipu6-nodes.sh
#               sudo ./hide-raw-ipu6-nodes.sh revert

set -eu

RULE=/etc/udev/rules.d/72-ipu6-isys-hide.rules

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

show_state() {
    echo "  /dev/video0  $(stat -c '%U:%G %a' /dev/video0 2>/dev/null)  <- the working one"
    echo "  /dev/video1  $(stat -c '%U:%G %a' /dev/video1 2>/dev/null)"
    printf '  visible to you: '
    n=0
    for d in /dev/video*; do [ -r "$d" ] && n=$((n + 1)); done
    echo "$n of $(ls /dev/video* | wc -l) nodes readable"
}

echo "== before =="
show_state

if [ "${1:-apply}" = "revert" ]; then
    rm -f "$RULE"
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=video4linux
    sleep 2
    echo
    echo "== after revert =="
    show_state
    exit 0
fi

cat > "$RULE" <<'EOF'
# The IPU6 raw ISYS capture nodes are Bayer sinks feeding the ISP; they cannot
# serve a webcam request, and listing them just gives users dozens of dead
# camera entries to choose from. Ubuntu's 72-intel-mipi-ipu6-camera.rules drops
# the uaccess ACL, but the nodes are group "video" and the desktop user is in
# that group, so that alone does not hide them. Take them out of the group too.
#
# /dev/video0 is ID_V4L_PRODUCT="Intel MIPI Camera" (the v4l2loopback fed by
# v4l2-relayd) and is deliberately not matched.
SUBSYSTEM=="video4linux", ENV{ID_V4L_PRODUCT}=="ipu6", GROUP="root", MODE="0660"
EOF

echo
echo "== rule written to $RULE =="
udevadm control --reload-rules
udevadm trigger --subsystem-match=video4linux
sleep 2

echo
echo "== after =="
show_state

echo
echo "Restart the browser, then re-check its camera list."
echo "Note: 'cam' now needs sudo. Revert with: sudo $0 revert"
