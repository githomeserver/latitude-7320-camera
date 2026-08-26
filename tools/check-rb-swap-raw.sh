#!/bin/bash
# Raw-Bayer CFA phase test. Stops v4l2-relayd for exclusive access.
# Usage: sudo ./check-rb-swap-raw.sh red|blue|green
set -u
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
C="${1:-red}"
trap 'systemctl start ov5678-ondemand.service 2>/dev/null || true' EXIT
systemctl stop ov5678-ondemand.service; sleep 2
python3 "$H/check-rb-swap-raw.py" "$C"
