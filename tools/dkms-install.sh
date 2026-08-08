#!/bin/bash
# Install the Latitude 7320 Detachable camera modules via DKMS, so they load at
# boot in place of their in-tree counterparts.
#
#   intel_skl_int3472_tps68470   TPS68470 board data          (Phase A)
#   ov5675                       + OVTI5678 acpi id           (Phase C)
#   ipu-bridge                   + OVTI5678 sensor config     (Phase B)
#
# All three must be in place at boot together: the INT3472 probe is one-shot
# per boot (acpi_dev_clear_dependencies frees the _DEP entries), and ipu-bridge
# only builds the fwnode graph during the ipu6 probe.
#
# Run as root:  sudo ./dkms-install.sh          install + build + depmod
#               sudo ./dkms-install.sh remove   undo, back to the in-tree modules

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
NAME="camera-dell7320"
VER="0.2"
DEST="/usr/src/$NAME-$VER"
OLD="int3472-dell7320"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

remove_pkg() {
    local n="$1" v="$2"
    dkms status -m "$n" 2>/dev/null | grep -q . && dkms remove -m "$n" -v "$v" --all || true
    rm -rf "/usr/src/$n-$v"
}

if [ "${1:-install}" = "remove" ]; then
    echo "== removing =="
    remove_pkg "$NAME" "$VER"
    remove_pkg "$OLD" "0.1"
    depmod -a
    echo "   removed. Reboot to go back to the in-tree modules."
    exit 0
fi

# The 0.1 package only carried the int3472 module; this supersedes it.
echo "== dropping superseded $OLD =="
remove_pkg "$OLD" "0.1"

echo
echo "== staging to $DEST =="
rm -rf "$DEST"
mkdir -p "$DEST"/{int3472,ov5675,ipu-bridge}
cp -f "$ROOT/module"/*.c "$ROOT/module"/*.h "$ROOT/module/Makefile"   "$DEST/int3472/"
cp -f "$ROOT/sensor-ov5675/ov5675.c" "$ROOT/sensor-ov5675/Makefile"   "$DEST/ov5675/"
cp -f "$ROOT/ipu-bridge/ipu-bridge.c" "$ROOT/ipu-bridge/Makefile"     "$DEST/ipu-bridge/"
rm -f "$DEST/int3472/dkms.conf"

cat > "$DEST/dkms.conf" <<EOF
PACKAGE_NAME="$NAME"
PACKAGE_VERSION="$VER"

BUILT_MODULE_NAME[0]="intel_skl_int3472_tps68470"
BUILT_MODULE_LOCATION[0]="int3472"
DEST_MODULE_LOCATION[0]="/updates/dkms"

BUILT_MODULE_NAME[1]="ov5675"
BUILT_MODULE_LOCATION[1]="ov5675"
DEST_MODULE_LOCATION[1]="/updates/dkms"

BUILT_MODULE_NAME[2]="ipu-bridge"
BUILT_MODULE_LOCATION[2]="ipu-bridge"
DEST_MODULE_LOCATION[2]="/updates/dkms"

MAKE[0]="make -C int3472 KDIR=\${kernel_source_dir} && make -C ov5675 KDIR=\${kernel_source_dir} && make -C ipu-bridge KDIR=\${kernel_source_dir}"
CLEAN="make -C int3472 clean; make -C ov5675 clean; make -C ipu-bridge clean"

AUTOINSTALL="yes"
EOF

echo
echo "== dkms add/build/install =="
dkms add -m "$NAME" -v "$VER"
dkms build -m "$NAME" -v "$VER"
dkms install -m "$NAME" -v "$VER" --force

echo
echo "== result =="
dkms status -m "$NAME"
depmod -a
for m in intel_skl_int3472_tps68470 ov5675 ipu-bridge; do
    printf '  %-30s %s\n' "$m" "$(modinfo -n "$m" 2>/dev/null || echo '??')"
done

echo
echo "All three must resolve to updates/dkms. Then reboot and run tools/check-camera.sh"
