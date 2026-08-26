#!/bin/bash
# Force libcamera's software ISP down the CPU debayer instead of the GPU one.
#
# WHY
#
# The AWB now computes red = 6.01 (correct; 6.13 is neutral), yet the output is
# still R/G 0.552. So the gain is not fully reaching the image. The GPU debayer
# has no gains uniform - its shader takes ccm, blacklevel, gamma, contrastExp -
# so the gains must be folded into params.combinedMatrix. The CPU debayer
# applies them directly via lookup tables instead.
#
# If CPU comes out neutral and GPU does not, the fault is in that folding.
#
# Run as root:  sudo ./try-cpu-isp.sh cpu      force the CPU debayer
#               sudo ./try-cpu-isp.sh gpu      back to the default (GPU)
set -u
D=/etc/systemd/system/v4l2-relayd@.service.d/40-softisp-mode.conf
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }
case "${1:-cpu}" in
cpu) mkdir -p "$(dirname "$D")"
     printf '[Service]\nEnvironment=LIBCAMERA_SOFTISP_MODE=cpu\n' > "$D"
     echo "forcing CPU debayer" ;;
gpu) rm -f "$D"; echo "back to default (GPU)" ;;
*)   echo "usage: $0 [cpu|gpu]" >&2; exit 1 ;;
esac
systemctl daemon-reload
systemctl restart ov5678-ondemand.service
sleep 6
printf 'service: '; systemctl is-active v4l2-relayd@default.service || true
echo
echo "now measure:  \"$(cd "$(dirname "$0")" && pwd)/check-colour.sh\""
