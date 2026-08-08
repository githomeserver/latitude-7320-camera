#!/bin/bash
# Collect the runtime ACPI camera data needed for TPS68470 board data (Phase A).
#
# The CLDB/SSDB buffers in the DSDT are placeholders; the real values are written
# at runtime from firmware NVS variables. So they must be read live via acpi_call.
#
# Run as root:  sudo ./collect-acpi.sh
# Output:       ../data/  (raw dumps, safe to re-run; nothing is modified)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/../data"
mkdir -p "$OUT"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (sudo $0)" >&2
    exit 1
fi

echo "== 1. acpi_call =="
if [ ! -e /proc/acpi/call ]; then
    if ! modprobe acpi_call 2>/dev/null; then
        echo "   acpi_call not available; installing acpi-call-dkms ..."
        apt-get install -y acpi-call-dkms || {
            echo "ERROR: install failed. Fallback is a debug hexdump in the int3472 probe path." >&2
            exit 1
        }
        modprobe acpi_call || { echo "ERROR: modprobe acpi_call failed" >&2; exit 1; }
    fi
fi
[ -e /proc/acpi/call ] || { echo "ERROR: /proc/acpi/call still missing" >&2; exit 1; }
echo "   ok"

# Evaluate one ACPI object and save the raw acpi_call reply.
call() {
    local path="$1" name="$2"
    printf '%s' "$path" > /proc/acpi/call 2>/dev/null
    # acpi_call returns a NUL-terminated string; strip the NUL.
    local reply
    reply="$(tr -d '\0' < /proc/acpi/call)"
    printf '%s\n' "$reply" > "$OUT/$name.raw"
    printf '   %-28s %s\n' "$name" "$(printf '%.90s' "$reply")"
}

echo
echo "== 2. Control logic (TPS68470 PMIC) and sensor link buffers =="
# CLP0 = INT3472:07, the live control logic. LNK0 = OVTI5678 (front), LNK1 = OVTI8856 (rear).
call '\_SB.PC00.CLP0.CLDB'  cldb_clp0
call '\_SB.PC00.CLP0._CRS'  crs_clp0
call '\_SB.PC00.LNK0.SSDB'  ssdb_lnk0
call '\_SB.PC00.LNK0._CRS'  crs_lnk0
call '\_SB.PC00.LNK0._PLD'  pld_lnk0
call '\_SB.PC00.LNK0._DDN'  ddn_lnk0
call '\_SB.PC00.LNK1.SSDB'  ssdb_lnk1
call '\_SB.PC00.LNK1._CRS'  crs_lnk1
call '\_SB.PC00.LNK1._PLD'  pld_lnk1
call '\_SB.PC00.LNK1._DDN'  ddn_lnk1

echo
echo "== 3. ACPI tables (for cross-checking how CLDB/SSDB get populated) =="
if command -v acpidump >/dev/null 2>&1; then
    acpidump -n DSDT -b -o "$OUT/dsdt.dat" 2>/dev/null || acpidump -b -n DSDT >/dev/null 2>&1
    # acpidump -b writes into cwd on some versions; normalise.
    [ -f dsdt.dat ] && mv -f dsdt.dat "$OUT/dsdt.dat"
    if [ -f "$OUT/dsdt.dat" ]; then
        echo "   dsdt.dat  $(stat -c %s "$OUT/dsdt.dat") bytes"
    else
        cp /sys/firmware/acpi/tables/DSDT "$OUT/dsdt.dat" && \
            echo "   dsdt.dat  $(stat -c %s "$OUT/dsdt.dat") bytes (from sysfs)"
    fi
else
    cp /sys/firmware/acpi/tables/DSDT "$OUT/dsdt.dat" 2>/dev/null && echo "   dsdt.dat (from sysfs)"
fi

echo
echo "== 4. Supporting state =="
{
    echo "### date"; date -Is
    echo "### kernel"; uname -r
    echo "### dmi"
    cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_version
    echo "### acpi camera devices (hid path status)"
    for d in /sys/bus/acpi/devices/*; do
        n=$(basename "$d")
        case "$n" in OVTI*|INT347*)
            printf '%s %s %s\n' "$n" "$(cat "$d/path" 2>/dev/null)" "$(cat "$d/status" 2>/dev/null)" ;;
        esac
    done
    echo "### i2c clients"; ls /sys/bus/i2c/devices/
    echo "### int3472/tps68470 kernel messages"
    journalctl -k -b 0 --no-pager | grep -iE 'int3472|tps68470' || true
} > "$OUT/system-state.txt" 2>&1
echo "   system-state.txt"

chmod -R a+r "$OUT" 2>/dev/null
chown -R --reference="$HERE" "$OUT" 2>/dev/null

echo
echo "Done. Now decode with:"
echo "    python3 '$HERE/decode-acpi.py'"
