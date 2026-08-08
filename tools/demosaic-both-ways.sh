#!/bin/bash
# Capture one raw frame and demosaic it as GRBG and as GBRG for comparison.
set -u
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
trap 'systemctl start v4l2-relayd.service 2>/dev/null || true' EXIT
systemctl stop v4l2-relayd.service; sleep 2
python3 "$H/demosaic-both-ways.py"
