#!/bin/bash
# Build both out-of-tree modules:
#   module/  -> intel_skl_int3472_tps68470  (TPS68470 board data, Phase A)
#   sensor/  -> ov5678                      (sensor driver, Phase C)
#
# Kbuild cannot handle spaces in M=<path> and this project lives under
# "Claude Code", so each is staged into a spaceless directory first. The
# directories under the project stay the single source of truth.
#
# Usage: ./build.sh [int3472|sensor]      (default: both)

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="${KVER:-$(uname -r)}"

# Resolve the *invoking* user's home, not $HOME: under sudo, HOME is /root,
# which would point the build and load scripts at different directories.
USER_HOME="$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)"
BASE="${OV5678_BUILD_DIR:-${USER_HOME:-$HOME}/.cache}"

build_one() {
    local src="$1" out="$2" ko="$3"

    echo "== $ko =="
    mkdir -p "$out"
    cp -f "$src"/*.c "$src"/Makefile "$out/"
    cp -f "$src"/*.h "$out/" 2>/dev/null || true

    make -C "/lib/modules/$KVER/build" M="$out" modules

    ls -la "$out/$ko.ko"
    modinfo "$out/$ko.ko" | grep -E '^(description|depends|parm|vermagic)' || true
    echo
}

what="${1:-both}"

if [ "$what" = "both" ] || [ "$what" = "int3472" ]; then
    build_one "$HERE/../module" "$BASE/ov5678-build" intel_skl_int3472_tps68470
fi

if [ "$what" = "both" ] || [ "$what" = "sensor" ]; then
    build_one "$HERE/../sensor" "$BASE/ov5678-sensor-build" ov5678
fi
