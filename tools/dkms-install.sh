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
# Run as root:  sudo ./dkms-install.sh                  install + build + depmod
#               sudo ./dkms-install.sh remove|revert   undo, back to in-tree modules

set -eu

# The board data matches on DMI strings, so these modules do nothing on any other
# machine - and there is a Dell Latitude 7320 *laptop* which is a different model
# without an IPU6. Refuse rather than install modules that cannot help.
MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
if [ "$MODEL" != "Latitude 7320 Detachable" ]; then
    echo "This machine reports: $MODEL" >&2
    echo "These modules only do anything on a 'Latitude 7320 Detachable'." >&2
    echo "Set FORCE=1 to install anyway." >&2
    [ "${FORCE:-0}" = 1 ] || exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
NAME="camera-dell7320"
VER="0.3"
DEST="/usr/src/$NAME-$VER"
# Every earlier package/version, so a rebuild never trips over
# "DKMS tree already contains" - including the same version, which is
# what happens when you rebuild without bumping.
OLD_PKGS="int3472-dell7320/0.1 camera-dell7320/0.2 camera-dell7320/0.3"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo $0)" >&2; exit 1; }

remove_pkg() {
    local n="$1" v="$2"
    dkms status -m "$n" 2>/dev/null | grep -q . && dkms remove -m "$n" -v "$v" --all || true
    rm -rf "/usr/src/$n-$v"
}

# Accept "revert" too: every other script in tools/ spells it that way, and
# silently falling through to a reinstall is the wrong way to handle a typo.
case "${1:-install}" in
    install|remove|revert) ;;
    *) echo "ERROR: unknown argument '$1' (expected: remove, revert, or nothing)" >&2
       exit 1 ;;
esac

if [ "${1:-install}" != "install" ]; then
    echo "== removing =="
    for pv in $OLD_PKGS; do remove_pkg "${pv%%/*}" "${pv##*/}"; done
    depmod -a
    echo "   removed. Reboot to go back to the in-tree modules."
    exit 0
fi

echo "== dropping any previous build =="
for pv in $OLD_PKGS; do
    if dkms status -m "${pv%%/*}" -v "${pv##*/}" 2>/dev/null | grep -q .; then
        echo "   removing $pv"
        remove_pkg "${pv%%/*}" "${pv##*/}"
    fi
done

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
