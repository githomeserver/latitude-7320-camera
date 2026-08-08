#!/bin/bash
# Build both out-of-tree modules:
#   module/          -> intel_skl_int3472_tps68470  (TPS68470 board data)
#   sensor-ov5675/   -> ov5675   (+OVTI5678 acpi id, +GBRG cfa phase)
#   ipu-bridge/      -> ipu-bridge  (+OVTI5678 sensor config)
#
# Kbuild cannot handle spaces in M=<path> and this project lives under
# "Claude Code", so each is staged into a spaceless directory first. The
# directories under the project stay the single source of truth.
#
# Usage: ./build.sh [int3472|ov5675|ipu-bridge]   (default: all)

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

what="${1:-all}"

if [ "$what" = "all" ] || [ "$what" = "int3472" ]; then
    build_one "$HERE/../module" "$BASE/ov5678-build" intel_skl_int3472_tps68470
fi

if [ "$what" = "all" ] || [ "$what" = "ov5675" ]; then
    build_one "$HERE/../sensor-ov5675" "$BASE/ov5678-sensor-ov5675-build" ov5675
fi

if [ "$what" = "all" ] || [ "$what" = "ipu-bridge" ]; then
    build_one "$HERE/../ipu-bridge" "$BASE/ov5678-ipu-bridge-build" ipu-bridge
fi
